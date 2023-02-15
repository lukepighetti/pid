import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

double d_factor(double d) => (-0.015 * d).clamp(-0.2, 0.2);
double i_factor(double i) => (-0.00007 * i).clamp(-0.3, 0.3);
double p_factor(double e) => (-0.005 * e).clamp(-0.5, 0.5) + 0.002 * t_set();
var d_span = Duration(minutes: 1);
var expire_span = Duration(minutes: 15);
var i_span = Duration(minutes: 2);
var sma_span = Duration(seconds: 60);
double t_set() => s.t_set.clamp(275, 500).toDouble();
var x_lerp = lerp(0.5, 0.95);

class State {
  var rawHistory = <Timestamped<double>>[];
  var errHistory = <Timestamped<double>>[];
  var t_set = 300.0;

  static final _file = File('data/state.json');

  Future<void> save() async {
    _file.writeAsStringSync(jsonEncode({
      'errHistory': TimestampedListSerializer.toJson(errHistory),
      'rawHistory': TimestampedListSerializer.toJson(rawHistory),
      'tSet': t_set,
    }));
  }

  Future<void> load() async {
    if (!_file.existsSync()) {
      _file.createSync(recursive: true);
      await save();
    }

    final d = _file.readAsStringSync().let(jsonDecode);
    errHistory = TimestampedListSerializer.fromJson(d['errHistory']);
    rawHistory = TimestampedListSerializer.fromJson(d['rawHistory']);
    t_set = d['tSet'];
  }

  void expire() {
    errHistory.expire(expire_span);
    rawHistory.expire(expire_span);
  }
}

final s = State();

final client = MqttServerClient('imac.local', '');

Future<void> main(List<String> arguments) async {
  await s.load();
  client.setProtocolV311();
  client.keepAlivePeriod = 30;
  await client.connect();

  const flueTopic = "esphome/woodstove/sensor/woodstove_flue_temperature/state";
  const setTopic = "pid/t_set";
  final topics = [flueTopic, setTopic];
  for (final topic in topics) {
    client.subscribe(topic, MqttQos.atMostOnce);
  }

  print(csv_row([
    't',
    't_set',
    't_err',
    'p_val',
    'i',
    'i_val',
    'd',
    'd_val',
    'x',
    'x_val',
  ]));

  Future<void> _listen() async {
    await for (final batch in client.updates!) {
      for (final message in batch) {
        final p = message.payload;
        if (p is! MqttPublishMessage) continue;
        final pt = MqttPublishPayload.bytesToStringAsString(p.payload.message);
        switch (message.topic) {
          case flueTopic:
            final t = pt.let(double.tryParse)?.let(c_to_f);
            if (t == null) continue;
            s.rawHistory.add(Timestamped.now(t));
            final t_setpoint = t_set();
            final t_err = t - t_setpoint;
            s.errHistory.add(Timestamped.now(t_err));

            final p_val = p_factor(t_err);
            final i = s.errHistory.integral(i_span);
            final i_val = i_factor(i);
            final d = s.rawHistory.derivative(d_span) ?? -0;
            final d_val = d_factor(d);

            final x = p_val + i_val + d_val;
            final x_val = x.clamp(0.0, 1.0).let(x_lerp);

            print(csv_row([
              t,
              t_setpoint,
              t_err,
              p_val,
              i,
              i_val,
              d,
              d_val,
              x,
              x_val,
            ]));

            s.expire();
            s.save();
            setTemp(x_val);
            break;

          case setTopic:
            final t = pt.let(double.tryParse);
            if (t == null) continue;
            s.t_set = t;
            s.save();
            break;

          default:
            print('<${message.topic}>: $pt');
        }
      }
    }
  }

  try {
    _listen();
  } on SocketException catch (e) {
    print("ERR: $e");
  }
}

extension ListTimestamped<T> on List<Timestamped<T>> {
  void expire(Duration limit) {
    removeWhere((e) => e.time.isBefore(DateTime.now().subtract(limit)));
  }

  List<Timestamped<T>> window(Duration limit) {
    final list = [...this];
    list.expire(limit);
    return list;
  }
}

extension ListTimestampedDouble on List<Timestamped<double>> {
  double? derivative(
    Duration window, {
    Duration timeUnit = const Duration(minutes: 1),
  }) {
    final windowedData = this.window(window);
    if (windowedData.length < 2) return null;
    final dy = windowedData.last.value - windowedData.first.value;
    final dx = windowedData.last.time.difference(windowedData.first.time);
    if (dx == 0) return null;
    final dydx = dy / dx.inDecimalSeconds;
    if (dydx.isNaN) return null;
    return dydx * timeUnit.inDecimalSeconds;
  }

  double integral(Duration window) {
    final windowedData = this.window(window);
    var result = 0.0;
    for (var i = 1; i < windowedData.length; i++) {
      final a = windowedData[i - 1];
      final b = windowedData[i];
      final dt = b.time.difference(a.time).inDecimalSeconds;
      result += ((a.value + b.value) / 2) * dt;
    }
    return result;
  }

  double average(Duration window) {
    final windowedData = this.window(window);
    final sum = windowedData.fold<double>(0, (a, b) => a + b.value);
    return sum / windowedData.length;
  }
}

class DerivativeResult {
  DerivativeResult(this.value, this.window);
  final double value;
  final Duration window;
}

extension Let<T> on T {
  K let<K>(K Function(T) fn) => fn(this);
}

double c_to_f(double c) => c * 9 / 5 + 32;

double Function(double) lerp(double a, double b) => (t) => a + (b - a) * t;

String csv_row(List<Object?> values) => values.map((it) {
      const padding = 7;
      if (it is num) {
        return it.toStringAsPrecision(3).padLeft(padding);
      } else {
        return it.toString().padLeft(padding);
      }
    }).join(",");

class Timestamped<T> {
  Timestamped.now(this.value) : time = DateTime.now().toUtc();
  Timestamped(this.time, this.value);
  final DateTime time;
  final T value;
}

extension on Duration {
  double get inDecimalSeconds => inMicroseconds * 1e-6;
}

class TimestampedListSerializer {
  static dynamic toJson(List<Timestamped<double>> list) {
    return list.map((e) => [e.time.toIso8601String(), e.value]).toList();
  }

  static List<Timestamped<double>> fromJson(List<dynamic> json) {
    return json
        .map((e) => Timestamped<double>(DateTime.parse(e[0]), e[1]))
        .toList();
  }
}

void setTemp(double x) {
  final builder = MqttClientPayloadBuilder()
    ..addString(jsonEncode({"state": "ON", "brightness": 255 - x * 255}));
  client.publishMessage('esphome/development/light/linear_servo/command',
      MqttQos.atLeastOnce, builder.payload!);
}
