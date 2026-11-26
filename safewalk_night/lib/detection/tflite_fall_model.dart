import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'fall_model.dart';

const String kTfliteAsset = 'assets/models/fall_model.tflite';
const String kWeightsAsset = 'assets/models/fall_model.json';

/// On-device TensorFlow Lite inference of the fall classifier.
class TfliteFallModel implements FallModel {
  final Interpreter _interpreter;
  TfliteFallModel(this._interpreter);

  @override
  String get backend => 'TensorFlow Lite';

  @override
  double predict(List<double> features) {
    final input = [features];
    final output = [
      [0.0]
    ];
    _interpreter.run(input, output);
    return output[0][0];
  }
}

/// Loads the TFLite model; falls back to the pure-Dart network if the native
/// runtime is unavailable on this device.
Future<FallModel> loadFallModel() async {
  final mlp = MlpFallModel.fromJson(await rootBundle.loadString(kWeightsAsset));
  try {
    final interpreter = await Interpreter.fromAsset(kTfliteAsset);
    final model = TfliteFallModel(interpreter);
    // Sanity check: both back-ends must agree before TFLite is trusted.
    final probe = List<double>.from(mlp.mean);
    if ((model.predict(probe) - mlp.predict(probe)).abs() > 0.02) return mlp;
    return model;
  } catch (_) {
    return mlp;
  }
}
