import 'dart:math' as math;

import 'features.dart';

/// Technique 2 - statistical analysis of jerk and signal-magnitude area (SMA).
///
/// Instead of fixed limits it learns THIS user's normal walking (running mean
/// and variance of jerk and SMA) and scores how many standard deviations the
/// current window is away from that baseline. This is what makes the
/// sensitivity adapt to the person and to where the phone is carried.
class StatisticalDetector {
  // Population defaults, used until enough of the user's walking is seen.
  double _muJerk = 1.0, _varJerk = 0.36;
  double _muSma = 3.5, _varSma = 2.25;
  int _learned = 0;

  static const double _alpha = 0.05;
  static const double _minSdJerk = 0.35;

  int get baselineWindows => _learned;
  double get baselineSma => _muSma;
  double get baselineJerk => _muJerk;
  double get _sdJerk => math.max(math.sqrt(_varJerk), _minSdJerk);

  /// Feed a window that is known to be ordinary walking.
  void learn(WindowFeatures f) {
    final dj = f.maxJerk - _muJerk;
    _muJerk += _alpha * dj;
    _varJerk = (1 - _alpha) * (_varJerk + _alpha * dj * dj);
    final ds = f.sma - _muSma;
    _muSma += _alpha * ds;
    _varSma = (1 - _alpha) * (_varSma + _alpha * ds * ds);
    _learned++;
  }

  double jerkZScore(WindowFeatures f) => (f.maxJerk - _muJerk) / _sdJerk;

  /// Jerk outlier followed by a collapse of movement energy.
  double fallConfidence(WindowFeatures f) {
    final spike = 1 / (1 + math.exp(-(jerkZScore(f) - 4.0)));
    final collapse = 1 - (f.tailSma / (0.5 * _muSma)).clamp(0.0, 1.0);
    return spike * (0.35 + 0.65 * collapse);
  }

  /// Movement energy has dropped far below the user's own walking baseline.
  bool isAtRest(WindowFeatures f) => f.tailSma < 0.25 * _muSma;

  double stopConfidence(double stillSeconds, {required double warnAfter, required double alarmAfter}) =>
      ramp(stillSeconds, warnAfter, alarmAfter);
}
