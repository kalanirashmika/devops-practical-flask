# SafeWalk Night

AI-assisted, motion-pattern based safety companion for people walking alone at night
(Group 46). Android prototype built with Flutter.

## What the prototype does

| Objective | Where it lives |
|---|---|
| Safe Walk Session start / stop | `lib/services/session_controller.dart`, `lib/screens/home_screen.dart` |
| Fall / abnormal-stop detection with three techniques + confidence check | `lib/detection/` |
| Countdown with cancel, then automatic alert to trusted contacts with live location | `lib/screens/alert_screen.dart`, `lib/services/alert_service.dart` |
| Manual SOS, live location sharing | Home screen |
| Safer-route suggestion + community unsafe-locations map | `lib/screens/map_screen.dart`, `lib/services/route_service.dart` |

### Detection engine

Accelerometer and gyroscope data is resampled to 50 Hz and analysed in 3-second
windows, every half second, by three independent methods:

1. **Threshold rules** (`threshold_detector.dart`) - free-fall dip, impact spike,
   stillness and change of orientation.
2. **Statistical analysis** (`statistical_detector.dart`) - z-score of jerk and
   signal-magnitude area against a baseline learned from the user's own walking.
3. **ML classifier** (`fall_model.dart`, `tflite_fall_model.dart`) - a small neural
   network run on the device with TensorFlow Lite.

`fusion.dart` combines them with weights 0.35 / 0.25 / 0.40. An alarm needs the
weighted confidence to reach the trigger level **and** at least two methods to agree.
A prolonged stop after walking is checked separately by methods 1 and 2.

## Run it

```
flutter pub get
flutter run            # phone connected with USB debugging on
flutter test           # 48 unit / widget tests
flutter build apk --release --split-per-abi
```

On the Walk tab, **Simulate a fall (demo)** plays a simulated walk and fall through
the real detection pipeline, so the countdown and alert can be shown without anyone
actually falling.

## Retraining the model

`ml/train_fall_model.py` (Python, TensorFlow) regenerates
`assets/models/fall_model.tflite`, `assets/models/fall_model.json` and the test
fixture. Its feature code must stay identical to `lib/detection/features.dart`;
`test/detection_test.dart` checks that.

## Known limits of this prototype

- The ML model is trained on **simulated** motion data, not recordings of real falls,
  so its real-world accuracy is not yet measured.
- Data (contacts, reports, history) is stored on the phone only. The four reports
  shown on first launch are labelled sample data. `StorageBackend` in
  `lib/services/app_store.dart` is the place to plug in Cloud Firestore so reports
  are shared between users.
- The map uses OpenStreetMap tiles and routing and needs an internet connection.
- Alerts are sent as SMS from the user's own SIM, so normal SMS charges apply.
