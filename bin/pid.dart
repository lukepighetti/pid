import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const tempTopic = "esphome/woodstove/sensor/woodstove_flue_temperature/state";

var p_factor = -0.008;
var p_offset = 0.5;
var s_max = 0.9;
var s_min = 0.3;
var setPoint = 200;

final s_lerp = lerp(s_min, s_max);

Future<void> main(List<String> arguments) async {
  final client = MqttServerClient('imac.local', '');
  client.setProtocolV311();
  client.keepAlivePeriod = 30;
  await client.connect();

  final topics = [tempTopic];
  for (final topic in topics) {
    client.subscribe(topic, MqttQos.atMostOnce);
  }

  print(csv_row(['temp', 'err', 'p_val', 's', 's_val']));

  await for (final batch in client.updates!) {
    for (final message in batch) {
      final p = message.payload;
      if (p is! MqttPublishMessage) continue;
      final pt = MqttPublishPayload.bytesToStringAsString(p.payload.message);
      switch (message.topic) {
        case tempTopic:
          final t = pt.let(double.tryParse)?.let(c_to_f);
          if (t == null) continue;
          final err = t - setPoint;
          final p_val = p_factor * err + p_offset;
          final s = p_val;
          final s_val = s.clamp(0.0, 1.0).let(s_lerp);

          print(csv_row([t, err, p_val, s, s_val]));
          break;
        default:
          print('<${message.topic}>: $pt');
      }
    }
  }
}

extension Let<T> on T {
  K let<K>(K Function(T) fn) => fn(this);
}

double c_to_f(double c) => c * 9 / 5 + 32;
double Function(double) lerp(double a, double b) => (t) => a + (b - a) * t;
String csv_row(List<Object> values) => values.map((it) {
      const padding = 6;
      if (it is String) {
        return it.toString().padLeft(padding);
      } else if (it is num) {
        return it.toStringAsPrecision(3).padLeft(padding);
      }
    }).join(",");
