import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'firebase_options.dart';

const _channel = MethodChannel('sensor_service_channel');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SensorApp());
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

class SensorHome extends StatefulWidget {
  const SensorHome({super.key});

  @override
  State<SensorHome> createState() => _SensorHomeState();
}

class _SensorHomeState extends State<SensorHome> {
  String selectedActivity = 'SITTING';
  String? userId;

  bool isRecording = false;
  String? sessionId;
  String status = 'Idle';

  @override
  void initState() {
    super.initState();
    DeviceUserId.getOrCreate().then((id) => setState(() => userId = id));
  }

  Future<void> _start() async {
    final uid = userId;
    if (uid == null) return;

    final startTs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final sid = 'session_$startTs';

    setState(() {
      isRecording = true;
      sessionId = sid;
      status = 'Recording in background...';
    });

    await _channel.invokeMethod('startService', {
      'activity': selectedActivity,
      'sessionId': sid,
    });
  }

  Future<void> _stop() async {
    if (!isRecording) return;

    setState(() {
      status = 'Stopping and uploading...';
    });

    final res = await _channel.invokeMethod<Map>('stopService');
    final filePath = res?['filePath'] as String?;
    final sid = res?['sessionId'] as String?;

    setState(() {
      isRecording = false;
      sessionId = sid;
    });

    if (filePath == null || sid == null) {
      setState(() => status = 'Stop failed: missing file/session info');
      return;
    }

    try {
      await _waitForFileToBeReady(filePath);
      await _uploadCsv(filePath: filePath);
      setState(() => status = 'Upload complete');
    } catch (e) {
      setState(() => status = 'Upload failed: $e');
    }
  }

  Future<void> _waitForFileToBeReady(String filePath) async {
    final file = File(filePath);

    int stableCount = 0;
    int? lastSize;

    for (int i = 0; i < 50; i++) {
      if (!await file.exists()) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final size = await file.length();
      if (lastSize != null && size == lastSize && size > 0) {
        stableCount++;
      } else {
        stableCount = 0;
      }

      lastSize = size;

      if (stableCount >= 3) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _uploadCsv({required String filePath}) async {
    final uid = userId;
    if (uid == null) return;

    final file = File(filePath);
    final lines = await file.readAsLines();
    if (lines.length <= 1) return;

    final samplesCol = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('samples');

    WriteBatch batch = FirebaseFirestore.instance.batch();
    int ops = 0;

    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;

      final parts = line.split(',');
      if (parts.length < 9) continue;

      final ts = int.tryParse(parts[0]) ?? 0;
      final accX = double.tryParse(parts[1]) ?? 0.0;
      final accY = double.tryParse(parts[2]) ?? 0.0;
      final accZ = double.tryParse(parts[3]) ?? 0.0;
      final gyroX = double.tryParse(parts[4]) ?? 0.0;
      final gyroY = double.tryParse(parts[5]) ?? 0.0;
      final gyroZ = double.tryParse(parts[6]) ?? 0.0;
      final activity = parts[7];
      final sessionId = parts[8];

      batch.set(samplesCol.doc(), {
        'session_id': sessionId,
        'timestamp': ts,
        'acc_x': accX,
        'acc_y': accY,
        'acc_z': accZ,
        'gyro_x': gyroX,
        'gyro_y': gyroY,
        'gyro_z': gyroZ,
        'activity': activity,
      });

      ops++;
      if (ops >= 450) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
        ops = 0;
      }
    }

    if (ops > 0) {
      await batch.commit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = userId ?? '...';
    final sid = sessionId ?? '-';

    return Scaffold(
      appBar: AppBar(title: const Text('Sensor Data Collector')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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
              DropdownMenuItem(value: 'STAIRS', child: Text('STAIRS')),
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
            onPressed: userId == null ? null : (isRecording ? _stop : _start),
            child: Text(isRecording ? 'Stop Recording' : 'Start Recording'),
          ),
          const SizedBox(height: 16),
          Text(status),
          const SizedBox(height: 8),
          const Text('Recording continues in background via foreground service.'),
        ]),
      ),
    );
  }
}
