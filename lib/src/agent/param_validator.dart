/// JSON-schema validation and coercion of tool-call arguments.
///
/// Validates the fully parsed [ToolCall.arguments] map against the JSON
/// Schema subset tools declare in [Tool.parameters]. The supported subset:
///
/// - `type`: `string`, `number`, `integer`, `boolean`, `null`, `object`,
///   `array`, or a union list (`["string", "null"]`).
/// - `required`, `properties`, `items` (single schema or tuple list).
/// - `enum` (checked *after* coercion, so `"1"` matches `[1, 2]`).
/// - `default` (injected when the argument is missing).
///
/// Validation semantics are a merge of the two reference implementations
/// (see GOAL.md):
///
/// - From agenix's `_param_validator.dart`: required checks, enum
///   enforcement, scalar coercion, default injection, and pass-through of
///   undeclared keys (the model may send extras the tool handles).
/// - From pi's `utils/validation.ts`: recursion into nested `properties` and
///   `items`, union-type members, and the specific coercion rules
///   (`"42"` → `42`, `"true"`/`"false"` → booleans, `1`/`0` → booleans,
///   numbers/booleans → strings).
///
/// Divergences: pi delegates final checking to a TypeBox compiler; this is a
/// hand-rolled subset validator, so keywords outside the list above
/// (`pattern`, `minimum`, `allOf`/`anyOf`/`oneOf`, `additionalProperties`)
/// are ignored rather than enforced. Boolean string coercion is
/// case-insensitive (agenix), where pi only accepts exact `"true"`/`"false"`.
library;

import 'dart:convert';

import 'package:flutter_sandbox/flutter_sandbox.dart';

/// Validates [arguments] against the tool's JSON-schema [schema] and returns
/// a new map with coerced values and injected defaults. Undeclared keys pass
/// through unchanged. The input map is never mutated.
///
/// Throws [ToolValidationException] listing every violation when validation
/// fails. Streamed partial JSON never reaches this function: providers
/// accumulate [ToolCall.partialArguments] and only parse the complete JSON
/// into [ToolCall.arguments], so validation always runs on the final
/// arguments of a finished tool call.
Map<String, dynamic> validateToolArguments({
  required Map<String, dynamic> arguments,
  required Map<String, dynamic> schema,
  required String toolName,
}) {
  final errors = <String>[];
  final validated = _validateObject(arguments, schema, '', errors);
  if (errors.isNotEmpty) {
    throw ToolValidationException(
      toolName,
      'Validation failed for tool "$toolName":\n'
      '${errors.map((e) => '  - $e').join('\n')}\n\n'
      'Received arguments:\n${jsonEncode(arguments)}',
    );
  }
  return validated;
}

/// Validates an arbitrary [value] against the same JSON-schema subset
/// [validateToolArguments] enforces and returns every violation as a
/// `path.with.dots: message` string (`(root)` for the top level). An empty
/// result means valid.
///
/// This is the output-schema side of the param-validation machinery: tool
/// arguments are always top-level objects, but subagent output schemas (see
/// `lib/src/task/`) may constrain any JSON value. The same coercion rules
/// apply (`"42"` validates against an `integer` schema), and keywords
/// outside the supported subset are ignored rather than enforced.
List<String> validateJsonValue({
  required Object? value,
  required Map<String, dynamic> schema,
}) {
  final errors = <String>[];
  _validateValue(value, schema, '', errors);
  return [
    for (final error in errors) error.startsWith(': ') ? '(root)$error' : error,
  ];
}

Map<String, dynamic> _validateObject(
  Map<String, dynamic> arguments,
  Map<String, dynamic> schema,
  String path,
  List<String> errors,
) {
  final validated = <String, dynamic>{};
  final properties = schema['properties'];
  final propertySchemas = properties is Map
      ? properties.cast<String, dynamic>()
      : const <String, dynamic>{};
  final required = schema['required'];
  final requiredNames = required is List
      ? required.whereType<String>().toSet()
      : const <String>{};

  for (final entry in propertySchemas.entries) {
    _validateDeclaredProperty(
      entry.key,
      entry.value,
      arguments,
      requiredNames,
      path,
      validated,
      errors,
    );
  }
  _validateUndeclaredRequired(
    requiredNames,
    propertySchemas,
    arguments,
    path,
    validated,
    errors,
  );
  _passThroughUndeclared(arguments, propertySchemas, validated);
  return validated;
}

/// Validates one declared property [name] against its [propertySchema],
/// writing the coerced value (or injected default) into [validated] and
/// recording violations in [errors].
void _validateDeclaredProperty(
  String name,
  Object? propertySchema,
  Map<String, dynamic> arguments,
  Set<String> requiredNames,
  String path,
  Map<String, dynamic> validated,
  List<String> errors,
) {
  final propertyPath = path.isEmpty ? name : '$path.$name';
  if (propertySchema is! Map) {
    // Unusable schema node: pass the raw value through.
    if (arguments.containsKey(name)) validated[name] = arguments[name];
    return;
  }
  final schemaMap = propertySchema.cast<String, dynamic>();

  final hasValue = arguments.containsKey(name) && arguments[name] != null;
  if (!hasValue) {
    _validateMissingValue(
      name,
      schemaMap,
      arguments,
      requiredNames,
      propertyPath,
      validated,
      errors,
    );
    return;
  }

  final value = _validateValue(
    arguments[name],
    schemaMap,
    propertyPath,
    errors,
  );
  if (value case _Valid(:final coerced)) {
    validated[name] = coerced;
  }
}

/// Handles a declared property that is absent or explicitly `null`: explicit
/// `null` against a nullable schema, `default` injection, or the required
/// violation.
void _validateMissingValue(
  String name,
  Map<String, dynamic> schemaMap,
  Map<String, dynamic> arguments,
  Set<String> requiredNames,
  String propertyPath,
  Map<String, dynamic> validated,
  List<String> errors,
) {
  final hasNullType = _schemaTypes(schemaMap).contains('null');
  if (arguments.containsKey(name) && hasNullType) {
    validated[name] = null;
    return;
  }
  if (schemaMap.containsKey('default')) {
    validated[name] = schemaMap['default'];
    return;
  }
  if (requiredNames.contains(name)) {
    errors.add('$propertyPath: missing required parameter');
  }
}

/// Required keys without a declared property schema: only presence matters.
void _validateUndeclaredRequired(
  Set<String> requiredNames,
  Map<String, dynamic> propertySchemas,
  Map<String, dynamic> arguments,
  String path,
  Map<String, dynamic> validated,
  List<String> errors,
) {
  for (final name in requiredNames) {
    if (!propertySchemas.containsKey(name)) {
      if (!arguments.containsKey(name) || arguments[name] == null) {
        final propertyPath = path.isEmpty ? name : '$path.$name';
        errors.add('$propertyPath: missing required parameter');
      } else {
        validated[name] = arguments[name];
      }
    }
  }
}

/// Undeclared keys pass through (agenix semantics).
void _passThroughUndeclared(
  Map<String, dynamic> arguments,
  Map<String, dynamic> propertySchemas,
  Map<String, dynamic> validated,
) {
  for (final entry in arguments.entries) {
    if (!validated.containsKey(entry.key) &&
        !propertySchemas.containsKey(entry.key)) {
      validated[entry.key] = entry.value;
    }
  }
}

sealed class _ValueOutcome {
  const _ValueOutcome();
}

final class _Valid extends _ValueOutcome {
  const _Valid(this.coerced);

  final Object? coerced;
}

final class _Invalid extends _ValueOutcome {
  const _Invalid();
}

/// Validates and coerces a single value against [schema]. Records every
/// violation in [errors] and returns [_Invalid] when the value cannot be
/// coerced to any declared type.
_ValueOutcome _validateValue(
  Object? value,
  Map<String, dynamic> schema,
  String path,
  List<String> errors,
) {
  final types = _schemaTypes(schema);

  final typed = _coerceToDeclaredTypes(value, types, path, errors);
  if (typed == null) return const _Invalid();
  var (currentValue, coerced) = typed;

  // Normalize integral doubles for `integer` schemas (JSON decodes `42.0`
  // as a double; tools expect an int).
  if (coerced is double && types.contains('integer')) {
    final asInt = coerced.toInt();
    currentValue = asInt;
    coerced = asInt;
  }

  coerced = _validateNested(currentValue, coerced, schema, path, errors);

  return _checkEnum(coerced, schema, path, errors);
}

/// Coerces [value] to one of the declared [types] when none match directly.
/// Returns the (possibly coerced) value pair, or `null` after recording the
/// type violation in [errors] when no coercion succeeds.
(Object?, Object?)? _coerceToDeclaredTypes(
  Object? value,
  List<String> types,
  String path,
  List<String> errors,
) {
  if (types.isEmpty || types.any((type) => _matchesType(value, type))) {
    return (value, value);
  }
  Object? coerced = value;
  for (final type in types) {
    final candidate = _coercePrimitive(value, type);
    if (candidate case _Valid(coerced: final coercedValue)) {
      if (_matchesType(coercedValue, type)) {
        value = coercedValue;
        coerced = coercedValue;
        break;
      }
    }
  }
  if (!types.any((type) => _matchesType(value, type))) {
    errors.add('$path: expected ${_typeLabel(types)}, got ${_describe(value)}');
    return null;
  }
  return (value, coerced);
}

/// Recurses into `object`/`array` values, returning the validated structure;
/// scalar values keep [coerced] unchanged.
Object? _validateNested(
  Object? value,
  Object? coerced,
  Map<String, dynamic> schema,
  String path,
  List<String> errors,
) {
  if (_matchesType(value, 'object')) {
    return _validateObject(
      (value! as Map).cast<String, dynamic>(),
      schema,
      path,
      errors,
    );
  } else if (_matchesType(value, 'array')) {
    return _validateArray(value! as List, schema, path, errors);
  }
  return coerced;
}

/// Enforces the schema's `enum` (checked *after* coercion, so `"1"` matches
/// `[1, 2]`).
_ValueOutcome _checkEnum(
  Object? coerced,
  Map<String, dynamic> schema,
  String path,
  List<String> errors,
) {
  final enumValues = schema['enum'];
  if (enumValues is List && enumValues.isNotEmpty) {
    if (!enumValues.any((allowed) => _enumEquals(allowed, coerced))) {
      errors.add(
        '$path: must be one of ${jsonEncode(enumValues)}, '
        'got ${jsonEncode(coerced)}',
      );
      return const _Invalid();
    }
  }
  return _Valid(coerced);
}

List<Object?> _validateArray(
  List<dynamic> value,
  Map<String, dynamic> schema,
  String path,
  List<String> errors,
) {
  final items = schema['items'];
  if (items is! Map) return List.of(value);
  final itemSchema = items.cast<String, dynamic>();
  final result = <Object?>[];
  for (var i = 0; i < value.length; i++) {
    final outcome = _validateValue(value[i], itemSchema, '$path[$i]', errors);
    if (outcome case _Valid(:final coerced)) {
      result.add(coerced);
    } else {
      result.add(value[i]);
    }
  }
  return result;
}

List<String> _schemaTypes(Map<String, dynamic> schema) {
  return switch (schema['type']) {
    String type => [type],
    List types => types.whereType<String>().toList(),
    _ => const [],
  };
}

String _typeLabel(List<String> types) {
  return types.length == 1 ? types.single : 'one of ${types.join(', ')}';
}

bool _matchesType(Object? value, String type) {
  return switch (type) {
    'number' => value is num,
    'integer' =>
      value is int || (value is double && value == value.roundToDouble()),
    'boolean' => value is bool,
    'string' => value is String,
    'null' => value == null,
    'array' => value is List,
    'object' => value is Map,
    _ => true, // Unknown types are not enforced.
  };
}

/// Attempts to coerce a scalar [value] to [type]. Mirrors pi's
/// `coercePrimitiveByType` / agenix's `_coerce`.
_ValueOutcome _coercePrimitive(Object? value, String type) {
  return switch (type) {
    'number' => _coerceToNumber(value),
    'integer' => _coerceToInteger(value),
    'boolean' => _coerceToBoolean(value),
    'string' => _coerceToString(value),
    'null' => _coerceToNull(value),
    _ => const _Invalid(),
  };
}

_ValueOutcome _coerceToNumber(Object? value) {
  if (value is num) return _Valid(value);
  if (value is bool) return _Valid(value ? 1 : 0);
  if (value is String && value.trim().isNotEmpty) {
    final parsed = num.tryParse(value);
    if (parsed != null) return _Valid(parsed);
  }
  return const _Invalid();
}

_ValueOutcome _coerceToInteger(Object? value) {
  if (value is int) return _Valid(value);
  if (value is double) {
    if (value == value.roundToDouble()) return _Valid(value.toInt());
    return const _Invalid();
  }
  if (value is bool) return _Valid(value ? 1 : 0);
  if (value is String) return _coerceStringToInteger(value);
  return const _Invalid();
}

_ValueOutcome _coerceStringToInteger(String value) {
  if (value.trim().isNotEmpty) {
    final parsed = num.tryParse(value);
    if (parsed != null && parsed == parsed.roundToDouble()) {
      return _Valid(parsed.toInt());
    }
  }
  return const _Invalid();
}

_ValueOutcome _coerceToBoolean(Object? value) {
  if (value is bool) return _Valid(value);
  if (value is num) {
    if (value == 1) return const _Valid(true);
    if (value == 0) return const _Valid(false);
  }
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return const _Valid(true);
    if (lower == 'false') return const _Valid(false);
  }
  return const _Invalid();
}

_ValueOutcome _coerceToString(Object? value) {
  if (value is String) return _Valid(value);
  if (value is num || value is bool) return _Valid('$value');
  return const _Invalid();
}

_ValueOutcome _coerceToNull(Object? value) {
  if (value == null) return const _Valid(null);
  if (value == '' || value == 0 || value == false) {
    return const _Valid(null);
  }
  return const _Invalid();
}

bool _enumEquals(Object? allowed, Object? value) {
  if (allowed is num && value is num) return allowed == value;
  return allowed == value;
}

String _describe(Object? value) {
  return switch (value) {
    null => 'null',
    String s => '"$s"',
    _ => '$value (${value.runtimeType})',
  };
}
