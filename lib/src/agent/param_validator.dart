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

import '../exceptions.dart';

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
    final name = entry.key;
    final propertyPath = path.isEmpty ? name : '$path.$name';
    final propertySchema = entry.value;
    if (propertySchema is! Map) {
      // Unusable schema node: pass the raw value through.
      if (arguments.containsKey(name)) validated[name] = arguments[name];
      continue;
    }
    final schemaMap = propertySchema.cast<String, dynamic>();

    final hasValue =
        arguments.containsKey(name) && arguments[name] != null;
    if (!hasValue) {
      final hasNullType = _schemaTypes(schemaMap).contains('null');
      if (arguments.containsKey(name) && hasNullType) {
        validated[name] = null;
        continue;
      }
      if (schemaMap.containsKey('default')) {
        validated[name] = schemaMap['default'];
        continue;
      }
      if (requiredNames.contains(name)) {
        errors.add('$propertyPath: missing required parameter');
      }
      continue;
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

  // Required keys without a declared property schema: only presence matters.
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

  // Undeclared keys pass through (agenix semantics).
  for (final entry in arguments.entries) {
    if (!validated.containsKey(entry.key) &&
        !propertySchemas.containsKey(entry.key)) {
      validated[entry.key] = entry.value;
    }
  }

  return validated;
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

  Object? coerced = value;
  if (types.isNotEmpty && !types.any((type) => _matchesType(value, type))) {
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
      errors.add(
        '$path: expected ${_typeLabel(types)}, got ${_describe(value)}',
      );
      return const _Invalid();
    }
  }

  // Normalize integral doubles for `integer` schemas (JSON decodes `42.0`
  // as a double; tools expect an int).
  if (coerced is double && types.contains('integer')) {
    final asInt = coerced.toInt();
    value = asInt;
    coerced = asInt;
  }

  if (_matchesType(value, 'object')) {
    coerced = _validateObject(
      (value! as Map).cast<String, dynamic>(),
      schema,
      path,
      errors,
    );
  } else if (_matchesType(value, 'array')) {
    coerced = _validateArray(value! as List, schema, path, errors);
  }

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
    'integer' => value is int || (value is double && value == value.roundToDouble()),
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
  switch (type) {
    case 'number':
      if (value is num) return _Valid(value);
      if (value is bool) return _Valid(value ? 1 : 0);
      if (value is String && value.trim().isNotEmpty) {
        final parsed = num.tryParse(value);
        if (parsed != null) return _Valid(parsed);
      }
    case 'integer':
      if (value is int) return _Valid(value);
      if (value is double) {
        if (value == value.roundToDouble()) return _Valid(value.toInt());
        return const _Invalid();
      }
      if (value is bool) return _Valid(value ? 1 : 0);
      if (value is String && value.trim().isNotEmpty) {
        final parsed = num.tryParse(value);
        if (parsed != null && parsed == parsed.roundToDouble()) {
          return _Valid(parsed.toInt());
        }
      }
    case 'boolean':
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
    case 'string':
      if (value is String) return _Valid(value);
      if (value is num || value is bool) return _Valid('$value');
    case 'null':
      if (value == null) return const _Valid(null);
      if (value == '' || value == 0 || value == false) {
        return const _Valid(null);
      }
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
