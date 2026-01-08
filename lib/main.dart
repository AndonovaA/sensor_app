import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const SensorApp());
}

class SensorApp extends StatelessWidget {
  const SensorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SensorHome(),
    );
  }
}

class DeviceUserId {
  static const _key = 'device_user_id';

  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_key);
    if (existing != null && existing.isNotEmpty) return existing;

    final id = 'user_${const Uuid().v4()}';
    await prefs.setString(_key, id);
    return id;
  }
}

class SensorHome extends StatefulWidget {
  const SensorHome({super.key});

  @override
  State<SensorHome> createState() => _SensorHomeState();
}

class _SensorHomeState extends State<SensorHome> {
  String selectedActivity = 'SITTING';
  String? userId;

  static const int sampleHz = 20;
  static const int batchSize = 100;
  static const Duration flushInterval = Duration(seconds: 5);

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  Timer? _samplingTimer;
  Timer? _flushTimer;

  AccelerometerEvent? _latestAccel;
  GyroscopeEvent? _latestGyro;

  bool isRecording = false;

  String? sessionId;
  CollectionReference<Map<String, dynamic>>? _samplesCol;

  final List<Map<String, dynamic>> _buffer = [];
  bool _flushInProgress = false;

  @override
  void initState() {
    super.initState();

    DeviceUserId.getOrCreate().then((id) {
      setState(() => userId = id);
      _samplesCol = FirebaseFirestore.instance
          .collection('users')
          .doc(id)
          .collection('samples');
    });

    _accelSub = accelerometerEventStream().listen((event) {
      _latestAccel = event;
    });

    _gyroSub = gyroscopeEventStream().listen((event) {
      _latestGyro = event;
    });
  }

  @override
  void dispose() {
    _samplingTimer?.cancel();
    _flushTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (userId == null || _samplesCol == null) return;

    final startTs = DateTime.now().millisecondsSinceEpoch;
    final sid = 'session_$startTs';

    setState(() {
      isRecording = true;
      sessionId = sid;
      _buffer.clear();
    });

    _samplingTimer?.cancel();
    _samplingTimer = Timer.periodic(
      Duration(milliseconds: (1000 / sampleHz).round()),
      (_) => _captureSample(),
    );

    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(flushInterval, (_) {
      if (!isRecording) return;
      if (_buffer.isEmpty) return;
      unawaited(_flushBuffer());
    });
  }

  void _captureSample() {
    if (!isRecording) return;

    final accel = _latestAccel;
    final gyro = _latestGyro;
    final samplesCol = _samplesCol;
    final sid = sessionId;

    if (accel == null || gyro == null || samplesCol == null || sid == null) {
      return;
    }

    final ts = DateTime.now().millisecondsSinceEpoch;

    _buffer.add({
      'session_id': sid,
      'timestamp': ts,
      'acc_x': accel.x,
      'acc_y': accel.y,
      'acc_z': accel.z,
      'gyro_x': gyro.x,
      'gyro_y': gyro.y,
      'gyro_z': gyro.z,
      'activity': selectedActivity,
    });

    if (_buffer.length >= batchSize) {
      unawaited(_flushBuffer());
    }
  }

  Future<void> _flushBuffer() async {
    if (_flushInProgress) return;

    final samplesCol = _samplesCol;
    if (samplesCol == null) return;
    if (_buffer.isEmpty) return;

    _flushInProgress = true;

    final toWrite = List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();

    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final row in toWrite) {
        batch.set(samplesCol.doc(), row);
      }
      await batch.commit();
    } finally {
      _flushInProgress = false;
      if (_buffer.length >= batchSize) {
        unawaited(_flushBuffer());
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!isRecording) return;

    setState(() => isRecording = false);

    _samplingTimer?.cancel();
    _samplingTimer = null;

    _flushTimer?.cancel();
    _flushTimer = null;

    await _flushBuffer();

    setState(() {
      sessionId = null;
      _buffer.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = userId ?? '...';
    final sid = sessionId ?? '-';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sensor Data Collector'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Device user_id: $uid'),
            const SizedBox(height: 8),
            Text('session_id: $sid'),
            const SizedBox(height: 24),
            const Text(
              'Activity:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            DropdownButton<String>(
              value: selectedActivity,
              items: const [
                DropdownMenuItem(value: 'SITTING', child: Text('SITTING')),
                DropdownMenuItem(value: 'STANDING', child: Text('STANDING')),
                DropdownMenuItem(value: 'WALKING', child: Text('WALKING')),
                DropdownMenuItem(
                  value: 'STAIR_CLIMBING',
                  child: Text('STAIR_CLIMBING'),
                ),
              ],
              onChanged: isRecording
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => selectedActivity = v);
                    },
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: (userId == null)
                  ? null
                  : (isRecording ? _stopRecording : _startRecording),
              child: Text(isRecording ? 'Stop Recording' : 'Start Recording'),
            ),
            const SizedBox(height: 16),
            Text(
              isRecording
                  ? 'Sampling at $sampleHz Hz; batching every $batchSize rows; flush every ${flushInterval.inSeconds}s'
                  : 'Not recording',
            ),
          ],
        ),
      ),
    );
  }
}
