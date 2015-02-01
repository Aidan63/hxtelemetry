package hxtelemetry;

import sys.net.Socket;
import amf.io.Amf3Writer;
import haxe.ds.StringMap;

#if cpp
  import cpp.vm.Thread;
#end

class Config
{
  public var app_name:String = "My App";
  public var host:String = "localhost";
  public var port:Int = 7934;
  public var auto_event_loop:Bool = true;
  public var cpu_usage:Bool = true;
  public var profiler:Bool = true;
  public var allocations:Bool = true;
  public var singleton_instance:Bool = true;
}

class Timing {
  // Couldn't get an enum to work well wrt scope/access, still needed toString() anyway

  // Scout compatibility issue - real names
  public static inline var GC:String = ".gc.custom";
  public static inline var USER:String = ".as.doactions";
  public static inline var RENDER:String = ".rend.custom";
  public static inline var OTHER:String = ".other.custom";
  public static inline var NET:String = ".net.custom";
  public static inline var ENTER:String = ".enter";
  // CUSTOM(s:String, color:Int); // TODO: implement me? Sounds cool!
}

class HxTelemetry
{
  // Optional: singleton accessors
  public static var singleton(default,null):HxTelemetry;

  // Member objects
  var _config:Config;
  var _writer:Thread;

  // Timing helpers
  static var _abs_t0_usec:Float = Date.now().getTime()*1000;
  static inline function timestamp_ms():Float { return _abs_t0_usec/1000 + haxe.Timer.stamp()*1000; };
  static inline function timestamp_us():Float { return _abs_t0_usec + haxe.Timer.stamp()*1000000; };

  public function new(config:Config=null)
  {
    if (config==null) config = new Config();
    _config = config;

    if (_config.singleton_instance) {
      if (singleton!=null) throw "Cannot have two singletons of HxTelemetry!";
      singleton = this;
    }

    _writer = Thread.create(start_writer);
    _writer.sendMessage(Thread.current());
    _writer.sendMessage(config.host);
    _writer.sendMessage(config.port);
    _writer.sendMessage(config.app_name);
    if (!Thread.readMessage(true)) {
      _writer = null;
      return;
    }

    _method_names = new Array<String>();
    _samples = new Array<Int>();
    _alloc_types = new Array<String>();
    _alloc_details = new Array<Int>();
    _alloc_stackidmap = new Array<Int>();

#if cpp
    if (_config.allocations && !_config.profiler) {
      throw "HxTelemetry config.allocations requires config.profiler";
    }

    if (_config.profiler) {
#if !HXCPP_STACK_TRACE
      throw "Using the HXTelemetry Profiler requires -D HXCPP_STACK_TRACE or in project.xml: <haxedef name=\"HXCPP_STACK_TRACE\" />";
#end
      untyped __global__.__hxcpp_hxt_start_telemetry();
      // Remove initial bias
      if (_config.allocations) { untyped __global__.__hxcpp_hxt_ignore_allocs(-1); }
    }
#end

    if (config.auto_event_loop) setup_event_loop();
  }

  function setup_event_loop():Void
  {
#if openfl
    flash.Lib.stage.addEventListener("HXT_BEFORE_FRAME", advance_frame);
#elseif lime
    trace("Does lime have an event loop?");
#else
    trace("TODO: create separate thread for event loop? e.g. commandline tools");
#end
  }

  var _method_names:Array<String>;
  var _samples:Array<Int>;
  var _alloc_types:Array<String>;
  var _alloc_details:Array<Int>;
  var _alloc_stackidmap:Array<Int>;
  public function advance_frame(e=null)
  {
    if (_writer==null) return;

#if cpp
    untyped __global__.__hxcpp_hxt_ignore_allocs(1);
    if (_config.profiler) {
      untyped __global__.__hxcpp_hxt_dump_names(_method_names);
      if (_method_names.length>0) {
        // Scout compatibility issue - wants bytes, not array<string>
        _writer.sendMessage({"name":".sampler.methodNameMapArray","value":_method_names});
        _method_names = new Array<String>();
      }
      untyped __global__.__hxcpp_hxt_dump_samples(_samples);
      if (_samples.length>0) {
        var i:Int=0;
        while (i<_samples.length) {
          var depth = _samples[i++];
          var callstack:Array<Int> = new Array<Int>();
          for (j in 0...depth) {
            callstack.unshift(_samples[i++]);
          }
          var delta = _samples[i++];
          _writer.sendMessage({"name":".sampler.sample","value":{"callstack":callstack, "numticks":delta}});
        }
        _samples = new Array<Int>();
      }
      if (_config.allocations) {
        untyped __global__.__hxcpp_hxt_dump_allocations(_alloc_types, _alloc_details, _alloc_stackidmap);
        //trace(" -- got "+_alloc_types.length+" allocations, "+_alloc_details.length+" details!");
        if (_alloc_stackidmap.length>0) {
          _writer.sendMessage({"name":".memory.stackIdMap","value":_alloc_stackidmap});
          _alloc_stackidmap = new Array<Int>();
        }
        if (_alloc_types.length>0) {
          var i:Int=0;
          while (i<_alloc_types.length) {
            var type = _alloc_types[i];
            var id:Int = _alloc_details[i*3];
            var size:Int = _alloc_details[i*3+1];
            var stackid:Int = _alloc_details[i*3+2] + 1; // 1-indexed
            i++;            
            // Scout compatibility issues - value merged into base object, value also includes "time", e.g.
            //  {"name":".memory.newObject","value":{"size":20,"time":72655,"type":"[class Namespace]","id":65268272,"stackid":1}}
            _writer.sendMessage({"name":".memory.newObject","size":size, "type":type, "stackid":stackid, "id":id});
          }
          _alloc_types = new Array<String>();
          _alloc_details = new Array<Int>();
        }
      }
    }

    var gctime:Int = untyped __global__.__hxcpp_hxt_dump_gctime();
    if (gctime>0) {
      _writer.sendMessage({"name":Timing.GC,"delta":gctime,"span":gctime});
    }

    untyped __global__.__hxcpp_hxt_ignore_allocs(-1);
#end

    end_timing(Timing.ENTER);
  }

  var _last = timestamp_us();
  var _start_times:StringMap<Float> = new StringMap<Float>();
  public function start_timing(name:String):Void
  {
    if (_writer==null) return;

    var t = timestamp_us();
    _start_times.set(name, t);
  }
  public function end_timing(name:String):Void
  {
    if (_writer==null) return;

#if cpp
    untyped __global__.__hxcpp_hxt_ignore_allocs(1);
#end
    var t = timestamp_us();
    var data:Dynamic = {"name":name,"delta":Std.int(t-_last)}
    if (_start_times.exists(name)) {
      data.span = Std.int(t-_start_times.get(name));
    }
    _writer.sendMessage(data);
    _last = t;
#if cpp
    untyped __global__.__hxcpp_hxt_ignore_allocs(-1);
#end
  }

  private static function start_writer():Void
  {
    var socket:Socket = null;
    var writer:Amf3Writer;

    var hxt_thread:Thread = Thread.readMessage(true);
    var host:String = Thread.readMessage(true);
    var port:Int = Thread.readMessage(true);
    var app_name:String = Thread.readMessage(true);

    function cleanup()
    {
      if (socket!=null) {
        socket.close();
        socket = null;
      }
      writer = null;
    }

    var switch_to_nonamf = true;
    var amf_mode = true;

    function safe_write(data:Dynamic) {
      try {
        if (!amf_mode) {
          var msg:String = haxe.Serializer.run(data);
          socket.output.writeInt32(msg.length);
          socket.output.writeString(msg);
        } else {
          writer.write(data);
        }
      } catch (e:Dynamic) {
        cleanup();
      }
    }

    socket = new Socket();
    try {
      socket.connect(new sys.net.Host(host), port);
      if (amf_mode) {
        writer = new Amf3Writer(socket.output);
      }
      safe_write({"name":".swf.name","value":app_name, "hxt":switch_to_nonamf});
      if (switch_to_nonamf) amf_mode = false;
      hxt_thread.sendMessage(true);
    } catch (e:Dynamic) {
      trace("Failed connecting to Telemetry host at "+host+":"+port);
      hxt_thread.sendMessage(false);
    }

    while (true) {
      var data = Thread.readMessage(true);
      if (data!=null) {
        safe_write(data);
      }
      if (socket==null) break;
    }
    trace("HXTelemetry socket thread exiting");
  }
}
