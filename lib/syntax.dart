import 'package:collection/collection.dart' show IterableExtension;
import 'package:json_ast/json_ast.dart' show Node;
import 'package:json_to_dart/helpers.dart';

const String emptyListWarn = "list is empty";
const String ambiguousListWarn = "list is ambiguous";
const String ambiguousTypeWarn = "type is ambiguous";

class Warning {
  final String warning;
  final String path;

  Warning(this.warning, this.path);
}

Warning newEmptyListWarn(String path) {
  return Warning(emptyListWarn, path);
}

Warning newAmbiguousListWarn(String path) {
  return Warning(ambiguousListWarn, path);
}

Warning newAmbiguousType(String path) {
  return Warning(ambiguousTypeWarn, path);
}

class WithWarning<T> {
  final T result;
  final List<Warning> warnings;

  WithWarning(this.result, this.warnings);
}

class TypeDefinition {
  String? name;
  String? subtype;
  bool? isAmbiguous = false;
  bool _isPrimitive = false;

  factory TypeDefinition.fromDynamic(dynamic obj, Node? astNode) {
    bool isAmbiguous = false;
    final type = getTypeName(obj);
    if (type == 'List') {
      List<dynamic> list = obj;
      String elemType;
      if (list.length > 0) {
        elemType = getTypeName(list[0]);
        for (dynamic listVal in list) {
          if (elemType != getTypeName(listVal)) {
            isAmbiguous = true;
            break;
          }
        }
      } else {
        // when array is empty insert Null just to warn the user
        elemType = "Null";
      }
      return TypeDefinition(type,
          astNode: astNode, subtype: elemType, isAmbiguous: isAmbiguous);
    }
    return TypeDefinition(type, astNode: astNode, isAmbiguous: isAmbiguous);
  }

  TypeDefinition(this.name, {this.subtype, this.isAmbiguous, Node? astNode}) {
    if (subtype == null) {
      _isPrimitive = isPrimitiveType(this.name);
      if (this.name == 'int' && isASTLiteralDouble(astNode)) {
        this.name = 'double';
      }
    } else {
      _isPrimitive = isPrimitiveType('$name<$subtype>');
    }
    if (isAmbiguous == null) {
      isAmbiguous = false;
    }
  }

  bool operator ==(other) {
    if (other is TypeDefinition) {
      TypeDefinition otherTypeDef = other;
      return this.name == otherTypeDef.name &&
          this.subtype == otherTypeDef.subtype &&
          this.isAmbiguous == otherTypeDef.isAmbiguous &&
          this._isPrimitive == otherTypeDef._isPrimitive;
    }
    return false;
  }

  bool get isPrimitive => _isPrimitive;

  bool get isPrimitiveList => _isPrimitive && name == 'List';

  String _buildParseClass(String expression) {
    final properType = subtype != null ? subtype : name;
    return '$properType.fromJson($expression)';
  }

  String _buildToJsonClass(String expression, [bool notNull = false]) {
    return '$expression${notNull ? '!' : ''}.toJson()';
  }

  String jsonParseExpression(String key, bool privateField) {
    final jsonKey = "json['$key']";
    final fieldKey =
        fixFieldName(key, typeDef: this, privateField: privateField);
    if (isPrimitive) {
      if (name == "List") {
        return "$fieldKey = json['$key'].cast<$subtype>();";
      }
      return "$fieldKey = json['$key'];";
    } else if (name == "List" && subtype == "DateTime") {
      return "$fieldKey = json['$key'].map((v) => DateTime.tryParse(v));";
    } else if (name == "DateTime") {
      return "$fieldKey = DateTime.tryParse(json['$key']);";
    } else if (name == 'List') {
      // list of class
      return "$fieldKey = (json['$key'] is List) ? (json['$key'] as List).map((v) => $subtype.fromJson(v)).toList() : null;";
    } else {
      // class
      return "$fieldKey = json['$key'] != null ? ${_buildParseClass(jsonKey)} : null;";
    }
  }

  String toJsonExpression(String key, bool privateField) {
    final fieldKey =
        fixFieldName(key, typeDef: this, privateField: privateField);
    final thisKey = '$fieldKey';
    if (isPrimitive) {
      return "data['$key'] = $thisKey;";
    } else if (name == 'List') {
      // class list
      return """if ($thisKey != null) {
      data['$key'] = $thisKey!.map((v) => ${_buildToJsonClass('v')}).toList();
    }""";
    } else {
      // class
      return """if ($thisKey != null) {
      data['$key'] = ${_buildToJsonClass(thisKey, true)};
    }""";
    }
  }
}

class Dependency {
  String name;
  final TypeDefinition typeDef;

  Dependency(this.name, this.typeDef);

  String get className => camelCase(name);
}

class ClassDefinition {
  final String _name;
  final bool _privateFields;
  final bool _finalFields;
  final Map<String, TypeDefinition> fields = Map<String, TypeDefinition>();

  String get name => _name;

  bool get privateFields => _privateFields;

  bool get finalFields => _finalFields;

  List<Dependency> get dependencies {
    final dependenciesList = <Dependency>[];
    final keys = fields.keys;
    keys.forEach((k) {
      final f = fields[k]!;
      if (!f.isPrimitive) {
        dependenciesList.add(Dependency(k, f));
      }
    });
    return dependenciesList;
  }

  ClassDefinition(
    this._name, [
    this._privateFields = false,
    this._finalFields = false,
  ]);

  bool operator ==(other) {
    if (other is ClassDefinition) {
      ClassDefinition otherClassDef = other;
      return this.isSubsetOf(otherClassDef) && otherClassDef.isSubsetOf(this);
    }
    return false;
  }

  bool isSubsetOf(ClassDefinition other) {
    final List<String> keys = this.fields.keys.toList();
    final int len = keys.length;
    for (int i = 0; i < len; i++) {
      TypeDefinition? otherTypeDef = other.fields[keys[i]];
      if (otherTypeDef != null) {
        TypeDefinition? typeDef = this.fields[keys[i]];
        if (typeDef != otherTypeDef) {
          return false;
        }
      } else {
        return false;
      }
    }
    return true;
  }

  hasField(TypeDefinition otherField) {
    return fields.keys.firstWhereOrNull((k) => fields[k] == otherField) != null;
  }

  addField(String name, TypeDefinition typeDef) {
    fields[name] = typeDef;
  }

  void _addTypeDef(TypeDefinition typeDef, StringBuffer sb) {
    sb.write('${typeDef.name}');
    if (typeDef.subtype != null) {
      sb.write('<${typeDef.subtype}>');
    }
  }

  String get _fieldList {
    return fields.keys.map((key) {
      final f = fields[key]!;
      final fieldName =
          fixFieldName(key, typeDef: f, privateField: privateFields);
      final sb = StringBuffer();
      sb.write('\t');
      if (finalFields) {
        sb.write('final ');
      }
      _addTypeDef(f, sb);
      sb.write('? $fieldName;');
      return sb.toString();
    }).join('\n');
  }

  String get _gettersSetters {
    return fields.keys.map((key) {
      final f = fields[key]!;
      final publicFieldName =
          fixFieldName(key, typeDef: f, privateField: false);
      final privateFieldName =
          fixFieldName(key, typeDef: f, privateField: true);
      final sb = StringBuffer();
      sb.write('\t');
      _addTypeDef(f, sb);
      sb.write('? get $publicFieldName => $privateFieldName;');
      if (!finalFields) {
        sb.write('\n\tset $publicFieldName(');
        _addTypeDef(f, sb);
        sb.write(
            '? $publicFieldName) => $privateFieldName = $publicFieldName;');
      }
      return sb.toString();
    }).join('\n');
  }

  String get _defaultPrivateConstructor {
    final sb = StringBuffer();
    sb.write('\t$name({');
    var i = 0;
    var len = fields.keys.length - 1;
    fields.keys.forEach((key) {
      final f = fields[key]!;
      final publicFieldName =
          fixFieldName(key, typeDef: f, privateField: false);
      _addTypeDef(f, sb);
      sb.write('? $publicFieldName');
      if (i != len) {
        sb.write(', ');
      }
      i++;
    });
    sb.write(',}) {\n');
    fields.keys.forEach((key) {
      final f = fields[key];
      final publicFieldName =
          fixFieldName(key, typeDef: f, privateField: false);
      final privateFieldName =
          fixFieldName(key, typeDef: f, privateField: true);
      sb.write('this.$privateFieldName = $publicFieldName;\n');
    });
    sb.write('}');
    return sb.toString();
  }

  String get _defaultConstructor {
    final sb = StringBuffer();
    sb.write('\t$name({');
    var i = 0;
    var len = fields.keys.length - 1;
    fields.keys.forEach((key) {
      final f = fields[key];
      final fieldName =
          fixFieldName(key, typeDef: f, privateField: privateFields);
      if (finalFields) {
        sb.write('this.$fieldName');
      } else {
        sb.write('this.$fieldName');
      }
      if (i != len) {
        sb.write(', ');
      }
      i++;
    });
    sb.write(',});');
    return sb.toString();
  }

  String get _jsonParseFunc {
    final sb = StringBuffer();
    sb.write('\t$name');
    if (finalFields) {
      sb.write('.fromJson(Map<String, dynamic> json) :\n');
      fields.keys.forEach((k) {
        final end = fields.keys.last == k;
        String fieldInitializer =
            fields[k]!.jsonParseExpression(k, privateFields);
        if (end) {
          if (!fieldInitializer.endsWith(';')) {
            fieldInitializer = '$fieldInitializer;';
          }
        } else {
          fieldInitializer = fieldInitializer.replaceFirst(';', ',');
        }
        sb.write('\t\t$fieldInitializer\n');
      });
    } else {
      sb.write('.fromJson(Map<String, dynamic> json) {\n');
      fields.keys.forEach((k) {
        sb.write('\t\t${fields[k]!.jsonParseExpression(k, privateFields)}\n');
      });
      sb.write('\t}');
    }
    return sb.toString();
  }

  String get _jsonGenFunc {
    final sb = StringBuffer();
    sb.write(
        '\tMap<String, dynamic> toJson() {\n\t\tfinal Map<String, dynamic> data = Map<String, dynamic>();\n');
    fields.keys.forEach((k) {
      sb.write('\t\t${fields[k]!.toJsonExpression(k, privateFields)}\n');
    });
    sb.write('\t\treturn data;\n');
    sb.write('\t}');
    return sb.toString();
  }

  String toString() {
    if (privateFields) {
      return 'class $name {\n$_fieldList\n\n$_defaultPrivateConstructor\n\n$_gettersSetters\n\n$_jsonParseFunc\n\n$_jsonGenFunc\n}\n';
    } else {
      return 'class $name {\n$_fieldList\n\n$_defaultConstructor\n\n$_jsonParseFunc\n\n$_jsonGenFunc\n}\n';
    }
  }
}
