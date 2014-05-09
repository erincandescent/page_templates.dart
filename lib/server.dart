library page_templates;
import 'dart:async';
import 'dart:mirrors';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:html5lib/dom.dart';
import 'package:html5lib/parser.dart';
import 'package:logging/logging.dart';

var _l = new Logger("Template");

class Template {
  static final String _structurePrefix = "structure:";
  final Document _templateDoc;
  
  Template(this._templateDoc);

  Template.fromString(String frag) : this(parse(frag));
  
  List<String> splitOnce(String haystack, String needle) {
    int idx = haystack.indexOf(needle);
    if(idx != -1) {
      return [haystack.substring(0, idx), haystack.substring(idx + needle.length)];
    } else {
      return [haystack, ""];
    }
  }
  
  static Future _evaluateExpression(String code, Map<String, Object> context) {
    // TALES path expressions - for now
    List<String> parts = code.trim().split("/");
    
    return _evaluateExpressionStep(parts, context);
  }
    
  static Future _evaluateExpressionStep(List<String> parts, 
                                  dynamic context, 
                                  [parent, parentExpr]) { 
    if(parts.isEmpty)
      return new Future.value(context);
    
    String part = parts.removeAt(0);    
    return new Future.sync(() {      
      InstanceMirror mirror = reflect(context);
      Symbol symbol = new Symbol(part);
      var val;
      try {
        val = mirror.getField(symbol).reflectee;
      } catch(e) {
        val = context[part];
      }
      
      if(val is Function)
        val = val();

      return val;
    }).catchError((e) {
      _l.warning("While evaluating ${part} at ${context} from [${parent}]/${parentExpr}", e);
      return ""; 
    }).then((v) =>_evaluateExpressionStep(parts, v, context, part));
  }
  
  static Future _evaluateStringExpression(String code, 
                                          Map<String, Object> context) {
    var structure = false; 
    if(code.startsWith(_structurePrefix)) {
      structure = true;
      code = code.substring(_structurePrefix.length);
    }
    
    return _evaluateExpression(code, context).then((value) {
      if(structure) {
        if(value is Node) {
          return value;
        } else {
          return parseFragment(value.toString());
        }
      } else {
        return value.toString();
      }
    });
  }
  
  Future<Node> _evaluateBodyExpression(String code, 
        Map<String, Object> context) 
  => _evaluateStringExpression(code, context).then((res) {
    if(res is Node) {
      return res; 
    } else {      
      return new Text(res.toString());
    }
  });
  
  _stepNodes(iter, output, context) {
    step() {
      if(!iter.moveNext()) return output;
      var child = iter.current;
      
      if(child is Element) {
        return _evaluateInContainer(output, child, context)
            .then((_) => step());
      } else {
        output.insertBefore(child.clone(), null);
        return new Future.sync(step);
      }
    }
    return step;
  }
  
  Future<Node> _evaluateElement(Element elem, Map<String, Object> context) {
    //print("evaluateElement ${elem}");
    var replace = elem.attributes.remove("tal:replace");
    if(replace != null) {
      return _evaluateBodyExpression(replace, context);
    }
    
    Node newElem = elem.clone();
    return new Future.sync(() {    
      var content    = newElem.attributes.remove("tal:content");
      if(content != null) {
        return _evaluateBodyExpression(content, context).then((val) {
          newElem.insertBefore(val, null);
        });
      } else {
        return new Future.sync(_stepNodes(elem.nodes.iterator, 
                                          newElem, context));
      }
    }).then((_) {
      var attributes = newElem.attributes.remove("tal:attributes");
      if(attributes != null) {
        return Future.forEach(attributes.split(";"), (attr) {
          var parts = splitOnce(attr, " ");
          var name = parts[0].trim();
          return _evaluateStringExpression(parts[1].trim(), context).then((val) {
            newElem.attributes[name] = val;
          });
        });
      }
    }).then((_) => newElem);
  }
  
  Future _evaluateInContainer(Node parent, Element elem, Map<String, Object> context) {
    return new Future.sync(() {
      var condition = elem.attributes.remove("tal:condition");
      if(condition != null) {
        return _evaluateExpression(condition, context);
      } else return true;
    }).then((shouldShow) {
      if(!shouldShow)
        return null;
      
      var repeat = elem.attributes.remove("tal:repeat");
      if(repeat != null) {
        var parts = splitOnce(repeat, " ");
        var var_ = parts[0].trim();
        var expr = parts[1].trim();
        
        return _evaluateExpression(expr, context).then((expr) {       
          if(expr is Iterable) {
            var all = expr.map((val) {
              var newContext = new Map.from(context);
              newContext[var_] = val;
              return _evaluateElement(elem, newContext);
            });
            
            return Future.wait(all).then((vals) {
              for(var val in vals)
                parent.insertBefore(val, null);
            });
          } else return new Future.value(null);
        });
      } else {
        return _evaluateElement(elem, context).then((value) {
          parent.insertBefore(value, null);
        });
      }
    });
  }
  
  Future<Document> evaluate(Map<String, Object> context) {
    Document output = _templateDoc.clone();
    
    var iter = _templateDoc.nodes.iterator;
    
    return new Future.sync(_stepNodes(iter, output, context));
  }
}

class TemplateLibrary {
  String basePath;
  Map<String, Template> _templates;
  
  TemplateLibrary(String libName)
      : basePath = path.join(Platform.script.resolve('packages').toFilePath(), libName)
  {
    //print("Base path " + basePath);
  }
  
  Template operator [](String name) {
    String filePath = path.join(basePath, name);
    return new Template.fromString(new File(filePath).readAsStringSync());
  }
}