import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Map<String, dynamic> _validate(
  Map<String, dynamic> arguments,
  Map<String, dynamic> schema,
) {
  return validateToolArguments(
    arguments: arguments,
    schema: schema,
    toolName: 'test_tool',
  );
}

void _expectInvalid(
  Map<String, dynamic> arguments,
  Map<String, dynamic> schema, {
  String? expected,
}) {
  expect(
    () => _validate(arguments, schema),
    throwsA(
      isA<ToolValidationException>()
          .having((e) => e.toolName, 'toolName', 'test_tool')
          .having(
            (e) => e.message,
            'message',
            expected == null ? anything : contains(expected),
          ),
    ),
  );
}

void main() {
  group('validateToolArguments', () {
    test('empty schema passes arguments through unchanged', () {
      final args = {'anything': 1, 'extra': 'yes'};
      final result = _validate(args, const {});
      expect(result, args);
    });

    test('valid typed arguments pass unchanged', () {
      final result = _validate(
        {'name': 'bob', 'age': 42, 'admin': true},
        const {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'age': {'type': 'integer'},
            'admin': {'type': 'boolean'},
          },
          'required': ['name', 'age', 'admin'],
        },
      );
      expect(result, {'name': 'bob', 'age': 42, 'admin': true});
    });

    test('missing required parameter throws', () {
      _expectInvalid(const {}, const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      }, expected: 'path');
    });

    test('null value for required parameter throws', () {
      _expectInvalid(
        const {'path': null},
        const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        expected: 'path',
      );
    });

    test('missing optional parameter is omitted from result', () {
      final result = _validate(
        const {'path': 'a.txt'},
        const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'encoding': {'type': 'string'},
          },
          'required': ['path'],
        },
      );
      expect(result, {'path': 'a.txt'});
    });

    test('default value is injected for missing parameter', () {
      final result = _validate(const {}, const {
        'type': 'object',
        'properties': {
          'encoding': {'type': 'string', 'default': 'utf-8'},
        },
      });
      expect(result, {'encoding': 'utf-8'});
    });

    test('required parameter with default uses default when missing', () {
      final result = _validate(const {}, const {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'default': 10},
        },
        'required': ['limit'],
      });
      expect(result, {'limit': 10});
    });

    test('unknown parameters pass through', () {
      final result = _validate(
        const {'path': 'a', 'mystery': true},
        const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      );
      expect(result, {'path': 'a', 'mystery': true});
    });

    group('scalar coercion', () {
      test('string "42" coerces to number and integer', () {
        final result = _validate(
          const {'n': '42', 'i': '42'},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'number'},
              'i': {'type': 'integer'},
            },
          },
        );
        expect(result, {'n': 42, 'i': 42});
      });

      test('fractional string coerces to number but not integer', () {
        final result = _validate(
          const {'n': '42.5'},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'number'},
            },
          },
        );
        expect(result, {'n': 42.5});
        _expectInvalid(
          const {'i': '42.5'},
          const {
            'type': 'object',
            'properties': {
              'i': {'type': 'integer'},
            },
          },
          expected: 'i',
        );
      });

      test('integral double coerces to integer', () {
        final result = _validate(
          const {'i': 42.0},
          const {
            'type': 'object',
            'properties': {
              'i': {'type': 'integer'},
            },
          },
        );
        expect(result, {'i': 42});
        expect(result['i'], isA<int>());
      });

      test('boolean coerces to number', () {
        final result = _validate(
          const {'n': true, 'm': false},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'number'},
              'm': {'type': 'integer'},
            },
          },
        );
        expect(result, {'n': 1, 'm': 0});
      });

      test('non-numeric string fails number coercion', () {
        _expectInvalid(
          const {'n': 'abc'},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'number'},
            },
          },
          expected: 'n',
        );
      });

      test('empty string fails number coercion', () {
        _expectInvalid(
          const {'n': '  '},
          const {
            'type': 'object',
            'properties': {
              'n': {'type': 'number'},
            },
          },
        );
      });

      test('string coerces to boolean (case-insensitive)', () {
        final result = _validate(
          const {'a': 'true', 'b': 'FALSE'},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'boolean'},
              'b': {'type': 'boolean'},
            },
          },
        );
        expect(result, {'a': true, 'b': false});
      });

      test('numbers 1 and 0 coerce to boolean', () {
        final result = _validate(
          const {'a': 1, 'b': 0},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'boolean'},
              'b': {'type': 'boolean'},
            },
          },
        );
        expect(result, {'a': true, 'b': false});
      });

      test('non-boolean string fails boolean coercion', () {
        _expectInvalid(
          const {'a': 'yes'},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'boolean'},
            },
          },
        );
      });

      test('number and bool coerce to string', () {
        final result = _validate(
          const {'a': 42, 'b': true},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
              'b': {'type': 'string'},
            },
          },
        );
        expect(result, {'a': '42', 'b': 'true'});
      });

      test('list fails string coercion', () {
        _expectInvalid(
          const {
            'a': [1],
          },
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
          },
        );
      });
    });

    group('enum', () {
      test('value in enum passes', () {
        final result = _validate(
          const {'mode': 'fast'},
          const {
            'type': 'object',
            'properties': {
              'mode': {
                'type': 'string',
                'enum': ['fast', 'slow'],
              },
            },
          },
        );
        expect(result, {'mode': 'fast'});
      });

      test('value outside enum throws', () {
        _expectInvalid(
          const {'mode': 'warp'},
          const {
            'type': 'object',
            'properties': {
              'mode': {
                'type': 'string',
                'enum': ['fast', 'slow'],
              },
            },
          },
          expected: 'mode',
        );
      });

      test('enum is checked after coercion', () {
        final result = _validate(
          const {'level': '1'},
          const {
            'type': 'object',
            'properties': {
              'level': {
                'type': 'integer',
                'enum': [1, 2],
              },
            },
          },
        );
        expect(result, {'level': 1});
      });
    });

    group('union types', () {
      test('value matching a union member passes', () {
        final result = _validate(
          const {'a': 'x', 'b': 5},
          const {
            'type': 'object',
            'properties': {
              'a': {
                'type': ['string', 'integer'],
              },
              'b': {
                'type': ['string', 'integer'],
              },
            },
          },
        );
        expect(result, {'a': 'x', 'b': 5});
      });

      test('value matching a union member is kept as-is (pi semantics)', () {
        // `"42"` matches the `string` member, so no coercion is attempted —
        // pi only coerces when the value matches no union member.
        final result = _validate(
          const {'a': '42'},
          const {
            'type': 'object',
            'properties': {
              'a': {
                'type': ['integer', 'string'],
              },
            },
          },
        );
        expect(result, {'a': '42'});
      });

      test('value matching no union member is coerced to the first fit', () {
        final result = _validate(
          const {'a': '42'},
          const {
            'type': 'object',
            'properties': {
              'a': {
                'type': ['integer', 'boolean'],
              },
            },
          },
        );
        expect(result, {'a': 42});
      });

      test('nullable union accepts null for optional parameter', () {
        final result = _validate(
          const {'a': null},
          const {
            'type': 'object',
            'properties': {
              'a': {
                'type': ['string', 'null'],
              },
            },
          },
        );
        expect(result, {'a': null});
      });

      test('value matching no union member throws', () {
        _expectInvalid(
          const {
            'a': [1],
          },
          const {
            'type': 'object',
            'properties': {
              'a': {
                'type': ['integer', 'string'],
              },
            },
          },
        );
      });
    });

    group('nested objects', () {
      const schema = {
        'type': 'object',
        'properties': {
          'address': {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
              'zip': {'type': 'integer'},
            },
            'required': ['city', 'zip'],
          },
        },
        'required': ['address'],
      };

      test('valid nested object passes', () {
        final result = _validate(const {
          'address': {'city': 'Berlin', 'zip': 10115},
        }, schema);
        expect(result, {
          'address': {'city': 'Berlin', 'zip': 10115},
        });
      });

      test('nested coercion applies', () {
        final result = _validate(const {
          'address': {'city': 'Berlin', 'zip': '10115'},
        }, schema);
        expect(result, {
          'address': {'city': 'Berlin', 'zip': 10115},
        });
      });

      test('missing nested required reports dotted path', () {
        _expectInvalid(
          const {
            'address': {'city': 'Berlin'},
          },
          schema,
          expected: 'address.zip',
        );
      });

      test('non-object value for object schema throws', () {
        _expectInvalid(const {'address': 'nope'}, schema, expected: 'address');
      });
    });

    group('arrays', () {
      test('valid array passes', () {
        final result = _validate(
          const {
            'tags': ['a', 'b'],
          },
          const {
            'type': 'object',
            'properties': {
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        );
        expect(result, {
          'tags': ['a', 'b'],
        });
      });

      test('items are coerced', () {
        final result = _validate(
          const {
            'counts': ['1', 2, 3.0],
          },
          const {
            'type': 'object',
            'properties': {
              'counts': {
                'type': 'array',
                'items': {'type': 'integer'},
              },
            },
          },
        );
        expect(result, {
          'counts': [1, 2, 3],
        });
      });

      test('invalid item reports indexed path', () {
        _expectInvalid(
          const {
            'counts': ['1', 'x'],
          },
          const {
            'type': 'object',
            'properties': {
              'counts': {
                'type': 'array',
                'items': {'type': 'integer'},
              },
            },
          },
          expected: 'counts[1]',
        );
      });

      test('non-array value throws', () {
        _expectInvalid(
          const {'tags': 'a'},
          const {
            'type': 'object',
            'properties': {
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
          expected: 'tags',
        );
      });

      test('array of nested objects validates each item', () {
        _expectInvalid(
          const {
            'points': [
              {'x': 1},
            ],
          },
          const {
            'type': 'object',
            'properties': {
              'points': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'x': {'type': 'integer'},
                    'y': {'type': 'integer'},
                  },
                  'required': ['x', 'y'],
                },
              },
            },
          },
          expected: 'points[0].y',
        );
      });
    });

    test('multiple errors are collected into one exception', () {
      try {
        _validate(
          const {'b': 'nope'},
          const {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
              'b': {'type': 'integer'},
            },
            'required': ['a'],
          },
        );
        fail('expected ToolValidationException');
      } on ToolValidationException catch (e) {
        expect(e.message, contains('a'));
        expect(e.message, contains('b'));
        expect(e.message, contains('test_tool'));
      }
    });

    test('input map is not mutated', () {
      final args = {'i': '42'};
      _validate(args, const {
        'type': 'object',
        'properties': {
          'i': {'type': 'integer'},
        },
      });
      expect(args, {'i': '42'});
    });

    test('required key without a property schema only checks presence', () {
      final result = _validate(
        const {'a': 1},
        const {
          'type': 'object',
          'required': ['a'],
        },
      );
      expect(result, {'a': 1});
      _expectInvalid(
        const {'a': 1},
        const {
          'type': 'object',
          'required': ['a', 'b'],
        },
        expected: 'b',
      );
    });

    test('non-map property schema passes the raw value through', () {
      final result = _validate(
        const {'a': 1},
        const {
          'type': 'object',
          'properties': {'a': 'string'},
        },
      );
      expect(result, {'a': 1});
    });

    test('fractional double fails integer coercion', () {
      _expectInvalid(
        const {'i': 4.5},
        const {
          'type': 'object',
          'properties': {
            'i': {'type': 'integer'},
          },
        },
      );
    });

    test('empty-ish scalars coerce to null for null-typed unions', () {
      final result = _validate(
        const {'a': '', 'b': 0, 'c': false},
        const {
          'type': 'object',
          'properties': {
            'a': {
              'type': ['null', 'integer'],
            },
            'b': {
              'type': ['null', 'string'],
            },
            'c': {
              'type': ['null', 'integer'],
            },
          },
        },
      );
      expect(result, {'a': null, 'b': null, 'c': null});
    });
  });
}
