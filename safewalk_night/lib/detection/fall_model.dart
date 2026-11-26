import 'dart:convert';
import 'dart:math' as math;

/// Technique 3 - a lightweight machine-learning classifier.
abstract class FallModel {
  /// Probability (0..1) that the 10-feature window is a fall.
  double predict(List<double> features);

  /// Human readable name of what is doing the inference.
  String get backend;
}

/// Pure-Dart inference of the trained network (10 -> 16 -> 8 -> 1).
///
/// Uses the same weights as the bundled TensorFlow Lite model; it is the
/// fallback when the TFLite runtime cannot load, and what unit tests run.
class MlpFallModel implements FallModel {
  final List<double> mean;
  final List<double> std;
  final List<List<List<double>>> weights; // [layer][out][in]
  final List<List<double>> biases; // [layer][out]
  final Map<String, dynamic> metrics;

  MlpFallModel({
    required this.mean,
    required this.std,
    required this.weights,
    required this.biases,
    this.metrics = const {},
  });

  factory MlpFallModel.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    List<double> vec(dynamic v) => (v as List).map((e) => (e as num).toDouble()).toList();
    final layers = j['layers'] as List;
    return MlpFallModel(
      mean: vec(j['mean']),
      std: vec(j['std']),
      weights: [for (final l in layers) (l['w'] as List).map(vec).toList()],
      biases: [for (final l in layers) vec(l['b'])],
      metrics: (j['metrics'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  @override
  String get backend => 'Dart MLP';

  @override
  double predict(List<double> features) {
    if (features.length != mean.length) {
      throw ArgumentError('Expected ${mean.length} features, got ${features.length}');
    }
    var x = [for (var i = 0; i < features.length; i++) (features[i] - mean[i]) / std[i]];
    for (var l = 0; l < weights.length; l++) {
      final last = l == weights.length - 1;
      final out = List<double>.filled(weights[l].length, 0);
      for (var o = 0; o < out.length; o++) {
        var sum = biases[l][o];
        final row = weights[l][o];
        for (var i = 0; i < row.length; i++) {
          sum += row[i] * x[i];
        }
        out[o] = last ? 1 / (1 + math.exp(-sum)) : math.max(0.0, sum);
      }
      x = out;
    }
    return x[0];
  }
}
