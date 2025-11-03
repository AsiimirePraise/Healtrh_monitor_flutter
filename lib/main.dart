import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'email_service.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_icon');
  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings();
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );
  
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  runApp(const HealthMonitorApp());
}

class HealthMonitorApp extends StatefulWidget {
  const HealthMonitorApp({Key? key}) : super(key: key);

  @override
  State<HealthMonitorApp> createState() => _HealthMonitorAppState();
}

class _HealthMonitorAppState extends State<HealthMonitorApp> {
  bool isDarkTheme = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VitaTrack Pro',
      theme: ThemeData(
        useMaterial3: true,
        brightness: isDarkTheme ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: isDarkTheme ? const Color(0xFF121212) : Color(0xFFF8F9FA),
        appBarTheme: AppBarTheme(
          backgroundColor: isDarkTheme ? Color(0xFF1E3A8A) : Color(0xFF3B82F6),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        colorScheme: isDarkTheme 
          ? ColorScheme.dark(primary: Color(0xFF60A5FA))
          : ColorScheme.light(primary: Color(0xFF1E40AF)),
      ),
      home: HealthMonitorHome(
        onThemeToggle: () => setState(() => isDarkTheme = !isDarkTheme),
        isDarkTheme: isDarkTheme,
      ),
    );
  }
}

class HealthMonitorHome extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDarkTheme;

  const HealthMonitorHome({
    required this.onThemeToggle,
    required this.isDarkTheme,
    Key? key,
  }) : super(key: key);

  @override
  State<HealthMonitorHome> createState() => _HealthMonitorHomeState();
}

class _HealthMonitorHomeState extends State<HealthMonitorHome> with TickerProviderStateMixin {
  List<BluetoothDevice> devices = [];
  BluetoothDevice? connectedDevice;
  
  int heartRate = 0;
  double temperature = 0;
  double humidity = 0;
  List<FlSpot> heartRateHistory = [];
  List<FlSpot> temperatureHistory = [];
  List<FlSpot> humidityHistory = [];
  
  bool isScanning = false;
  bool isConnected = false;
  bool heartAlert = false;
  bool tempAlert = false;
  bool humidityAlert = false;
  bool logsExpanded = false;
  
  // Email functionality variables
  List<Map<String, dynamic>> emailHistory = [];
  String patientName = '';
  bool showEmailHistory = false;
  
  // Tab controller for logs
  late TabController _tabController;
  
  List<String> logs = [];
  final Random random = Random();
  DateTime lastNotificationTime = DateTime.now().subtract(const Duration(minutes: 5));
  DateTime lastStableTempNotificationTime = DateTime.now().subtract(const Duration(minutes: 10));
  
  late Database db;
  StreamSubscription? characteristicSubscription;
  
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _fadeAnimation;

  // Temperature stability tracking
  List<double> recentTemperatures = [];
  static const int STABLE_TEMP_MINUTES = 5;
  static const int TEMP_READINGS_PER_MINUTE = 2; // Assuming data every 30 seconds
  static const int TOTAL_READINGS_NEEDED = STABLE_TEMP_MINUTES * TEMP_READINGS_PER_MINUTE;
  static const double STABLE_TEMP_THRESHOLD = 1.0; // ±1°C variation considered stable

  @override
  void initState() {
    super.initState();
    _initDB();
    _requestPermissions();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    
    _pulseAnimation = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    ));
    
    _animationController.repeat(reverse: true);
    
    // Initialize tab controller
    _tabController = TabController(length: 2, vsync: this);
  }

  Future<void> _initDB() async {
    final databasesPath = await getDatabasesPath();
    final pathStr = path.join(databasesPath, 'health_monitor.db');
    
    db = await openDatabase(
      pathStr,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute(
          'CREATE TABLE health_data ('
          'id INTEGER PRIMARY KEY,'
          'timestamp INTEGER,'
          'heart_rate INTEGER,'
          'temperature REAL,'
          'humidity REAL,'
          'heart_alert INTEGER,'
          'temp_alert INTEGER'
          ')',
        );
      },
    );
  }

  Future<void> _saveHealthData({
    required int heartRate,
    required double temperature,
    required double humidity,
    required bool heartAlert,
    required bool tempAlert,
  }) async {
    await db.insert(
      'health_data',
      {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'heart_rate': heartRate,
        'temperature': temperature,
        'humidity': humidity,
        'heart_alert': heartAlert ? 1 : 0,
        'temp_alert': tempAlert ? 1 : 0,
      },
    );
  }

  Future<void> _loadLatestData() async {
    final result = await db.query(
      'health_data',
      orderBy: 'timestamp DESC',
      limit: 10,
    );
    
    final data = result.reversed.toList();
    setState(() {
      heartRateHistory = List.generate(
        data.length,
        (i) => FlSpot(i.toDouble(), (data[i]['heart_rate'] as int).toDouble()),
      );
    });
  }

  Future<void> _requestPermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
    await Permission.notification.request();
    addLog('✓ Permissions requested');
  }

  Future<void> _sendEmailToDoctors() async {
     try {
       // Send email using EmailService
       await EmailService.sendPatientDataEmail(
         patientName: patientName.isEmpty ? 'Patient' : patientName,
         heartRate: heartRate,
         temperature: temperature,
         humidity: humidity,
         heartAlert: heartRate > 100 || heartRate < 60,
         tempAlert: temperature > 37.5 || temperature < 35.0,
         humidityAlert: humidity > 70 || humidity < 30,
       );
       
       // Update email history
       setState(() {
         emailHistory.add({
           'timestamp': DateTime.now().toString(),
           'recipient': EmailService.doctorEmails.join(', '),
           'status': 'Sent',
           'error': null,
         });
       });
       
       addLog(' Email sent successfully to doctors');
       _showNotification('Email Alert Sent', 'Medical staff has been notified of current vital signs.');
     } catch (e) {
       // Update email history with error
       setState(() {
         emailHistory.add({
           'timestamp': DateTime.now().toString(),
           'recipient': EmailService.doctorEmails.join(', '),
           'status': 'Failed',
           'error': e.toString(),
         });
       });
       
       addLog(' Email sending failed: $e');
     }
   }

  Future<void> _showNotification(String title, String body) async {
    final now = DateTime.now();
    final timeSinceLastNotification = now.difference(lastNotificationTime);
    
    if (timeSinceLastNotification.inMinutes >= 4) {
      const AndroidNotificationDetails androidPlatformChannelSpecifics =
          AndroidNotificationDetails(
        'health_alerts',
        'Health Alerts',
        channelDescription: 'Notifications for health monitoring alerts',
        importance: Importance.high,
        priority: Priority.high,
      );
      
      const NotificationDetails platformChannelSpecifics =
          NotificationDetails(android: androidPlatformChannelSpecifics);
      
      await flutterLocalNotificationsPlugin.show(
        random.nextInt(1000),
        title,
        body,
        platformChannelSpecifics,
      );
      
      lastNotificationTime = now;
      addLog('Notification sent: $title');
    }
  }

  Future<void> _showStableTemperatureNotification() async {
    final now = DateTime.now();
    final timeSinceLastStableNotification = now.difference(lastStableTempNotificationTime);
    
    if (timeSinceLastStableNotification.inMinutes >= 10) { // Prevent spam
      const AndroidNotificationDetails androidPlatformChannelSpecifics =
          AndroidNotificationDetails(
        'stable_temperature',
        'Temperature Status',
        channelDescription: 'Notifications for stable temperature conditions',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      
      const NotificationDetails platformChannelSpecifics =
          NotificationDetails(android: androidPlatformChannelSpecifics);
      
      String message = '';
      if (temperature > 28.0) {
        message = 'Temperature has been consistently high. Consider staying hydrated and in a cool area.';
      } else if (temperature < 20.0) {
        message = 'Temperature has been consistently cool. You might need a jacket or umbrella.';
      } else {
        message = 'Temperature has been stable and comfortable. Enjoy the pleasant conditions!';
      }
      
      await flutterLocalNotificationsPlugin.show(
        random.nextInt(1000) + 1000, // Different ID range
        'Stable Temperature Alert',
        message,
        platformChannelSpecifics,
      );
      
      lastStableTempNotificationTime = now;
      addLog('Stable temperature notification: ${temperature.toStringAsFixed(1)}°C');
    }
  }

  void _checkTemperatureStability(double newTemperature) {
    // Add new temperature to recent readings
    recentTemperatures.add(newTemperature);
    
    // Keep only the last 10 readings (5 minutes at 30-second intervals)
    if (recentTemperatures.length > TOTAL_READINGS_NEEDED) {
      recentTemperatures.removeAt(0);
    }
    
    // Check if we have enough data for stability analysis
    if (recentTemperatures.length >= TOTAL_READINGS_NEEDED) {
      double minTemp = recentTemperatures.reduce(min);
      double maxTemp = recentTemperatures.reduce(max);
      double variation = maxTemp - minTemp;
      
      // If temperature variation is within threshold, consider it stable
      if (variation <= STABLE_TEMP_THRESHOLD) {
        addLog('Temperature stable at ${newTemperature.toStringAsFixed(1)}°C (variation: ${variation.toStringAsFixed(1)}°C)');
        _showStableTemperatureNotification();
        recentTemperatures.clear(); // Reset after notification to avoid spam
      }
    }
  }

  void _checkAndSendAutomaticEmail(int heartRate, double temperature) async {
    // Check if heart rate is below 60 or temperature is outside normal range
    // Normal heart rate: 60-100 BPM
    // Normal body temperature: 28°C to 37°C (as per user request)
    bool shouldSendEmail = heartRate < 60 || temperature < 28.0 || temperature > 37.0;
    
    if (shouldSendEmail && patientName.isNotEmpty) {
      // Check if we've sent an email recently (to avoid spam)
      final now = DateTime.now();
      final lastEmailTime = emailHistory.isNotEmpty 
          ? DateTime.tryParse(emailHistory.last['timestamp'] ?? '') 
          : null;
      
      bool canSendEmail = true;
      if (lastEmailTime != null) {
        final difference = now.difference(lastEmailTime);
        // Only send email if at least 5 minutes have passed
        if (difference.inMinutes < 5) {
          canSendEmail = false;
        }
      }
      
      if (canSendEmail) {
        try {
          // Send email using EmailService
          await EmailService.sendPatientDataEmail(
            patientName: patientName,
            heartRate: heartRate,
            temperature: temperature,
            humidity: humidity,
            heartAlert: heartRate < 60, // Heart rate below normal
            tempAlert: temperature < 28.0 || temperature > 37.0, // Temperature outside normal range
            humidityAlert: humidity > 70 || humidity < 30,
          );
          
          // Update email history
          setState(() {
            emailHistory.add({
              'timestamp': DateTime.now().toString(),
              'recipient': EmailService.doctorEmails.join(', '),
              'status': 'Sent',
              'error': null,
            });
          });
          
          addLog(' Automatic email sent to doctors');
          _showNotification('Email Alert Sent', 'Medical staff has been notified of current vital signs.');
        } catch (e) {
          // Update email history with error
          setState(() {
            emailHistory.add({
              'timestamp': DateTime.now().toString(),
              'recipient': EmailService.doctorEmails.join(', '),
              'status': 'Failed',
              'error': e.toString(),
            });
          });
          
          addLog(' Automatic email sending failed: $e');
        }
      }
    }
  }

  void startScan() async {
    if (isScanning) return;
    
    setState(() {
      isScanning = true;
      devices = [];
    });

    addLog('Starting BLE scan...');

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          if (!devices.any((d) => d.remoteId == r.device.remoteId)) {
            setState(() => devices.add(r.device));
            addLog('📍 Found: ${r.device.platformName}');
          }
        }
      });

      Future.delayed(const Duration(seconds: 16), () async {
        await FlutterBluePlus.stopScan();
        setState(() => isScanning = false);
        addLog('✓ Scan completed');
      });
    } catch (e) {
      addLog(' Scan error: $e');
      setState(() => isScanning = false);
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    try {
      addLog('Connecting...');
      await device.connect();
      addLog('✓ Connected!');
      
      List<BluetoothService> services = await device.discoverServices();
      
      for (BluetoothService service in services) {
        for (BluetoothCharacteristic char in service.characteristics) {
          if (char.properties.notify || char.properties.indicate) {
            await char.setNotifyValue(true);
            addLog('Listening for data');
            
            characteristicSubscription = char.onValueReceived.listen((value) {
              handleBLEData(value);
            });
            break;
          }
        }
      }
      
      await _loadLatestData();
      
      setState(() {
        connectedDevice = device;
        isConnected = true;
      });
      
      addLog('✓ Ready!');
    } catch (e) {
      addLog('Connection failed: $e');
    }
  }

  void handleBLEData(List<int> value) {
    try {
      String jsonString = String.fromCharCodes(value);
      Map<String, dynamic> data = jsonDecode(jsonString);
      
      final newHeartRate = data['h'] ?? 0;
      final newTemp = (data['t'] ?? 0.0).toDouble();
      final newHumidity = (data['m'] ?? 0.0).toDouble();
      final newHeartAlert = data['a'] == 1;
      final newTempAlert = data['tx'] == 1;
      final newHumidityAlert = data['hm'] == 1;
      
      setState(() {
        heartRate = newHeartRate;
        temperature = newTemp;
        humidity = newHumidity;
        heartAlert = newHeartAlert;
        tempAlert = newTempAlert;
        humidityAlert = newHumidityAlert;
        
        // Update heart rate history
        heartRateHistory.add(FlSpot(heartRateHistory.length.toDouble(), newHeartRate.toDouble()));
        if (heartRateHistory.length > 10) {
          heartRateHistory.removeAt(0);
          for (int i = 0; i < heartRateHistory.length; i++) {
            heartRateHistory[i] = FlSpot(i.toDouble(), heartRateHistory[i].y);
          }
        }
        
        // Update temperature history
        temperatureHistory.add(FlSpot(temperatureHistory.length.toDouble(), newTemp));
        if (temperatureHistory.length > 10) {
          temperatureHistory.removeAt(0);
          for (int i = 0; i < temperatureHistory.length; i++) {
            temperatureHistory[i] = FlSpot(i.toDouble(), temperatureHistory[i].y);
          }
        }
        
        // Update humidity history
        humidityHistory.add(FlSpot(humidityHistory.length.toDouble(), newHumidity));
        if (humidityHistory.length > 10) {
          humidityHistory.removeAt(0);
          for (int i = 0; i < humidityHistory.length; i++) {
            humidityHistory[i] = FlSpot(i.toDouble(), humidityHistory[i].y);
          }
        }
      });
      
      _saveHealthData(
        heartRate: newHeartRate,
        temperature: newTemp,
        humidity: newHumidity,
        heartAlert: newHeartAlert,
        tempAlert: newTempAlert,
      );
      
      // Check if we should automatically send an email
      _checkAndSendAutomaticEmail(newHeartRate, newTemp);
      
      // Check temperature stability
      _checkTemperatureStability(newTemp);
      
      addLog('HR: $newHeartRate T: ${newTemp.toStringAsFixed(1)} H: ${newHumidity.toStringAsFixed(1)}');
      
      if (newHeartAlert) {
        final adviceList = [
          'Take deep breaths and relax.',
          'Try light stretching.',
          'Drink water and rest.',
          'Take a short walk.',
          'Practice relaxation.',
        ];
        final advice = adviceList[random.nextInt(adviceList.length)];
        _showNotification('High Heart Rate Alert', 'HR: $newHeartRate BPM. $advice');
      }
      
      if (newTempAlert) {
        final adviceList = [
          'Move to a cooler area.',
          'Use a cool compress.',
          'Remove excess clothing.',
          'Drink cool water.',
        ];
        final advice = adviceList[random.nextInt(adviceList.length)];
        _showNotification('High Temperature Alert', 'T: ${newTemp.toStringAsFixed(1)}°C. $advice');
      }
    } catch (e) {
      addLog('Parse error: $e');
    }
  }

  void disconnect() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
    }
    await characteristicSubscription?.cancel();
    
    setState(() {
      connectedDevice = null;
      isConnected = false;
      heartRate = 0;
      temperature = 0;
      humidity = 0;
      heartRateHistory = [];
      temperatureHistory = [];
      humidityHistory = [];
      recentTemperatures.clear();
    });
    
    addLog('Disconnected');
  }

  void addLog(String message) {
    final time = DateTime.now().toString().split(' ')[1].split('.')[0];
    setState(() {
      logs.insert(0, '$time: $message');
      if (logs.length > 50) logs.removeLast();
    });
  }

  void clearLogs() {
    setState(() {
      logs.clear();
    });
    addLog('Logs cleared');
  }

  // Heart rate status helper methods
  String _getHeartRateStatus(int rate) {
    if (rate == 0) return 'NO SIGNAL';
    if (rate < 60) return 'LOW (Below 60 BPM)';
    if (rate > 100) return 'HIGH (Above 100 BPM)';
    return 'NORMAL (60-100 BPM)';
  }

  Color _getHeartRateStatusColor(int rate) {
    if (rate == 0) return Colors.grey;
    if (rate < 60) return Colors.blue;
    if (rate > 100) return Colors.red;
    return Colors.green;
  }

  IconData _getHeartRateStatusIcon(int rate) {
    if (rate == 0) return Icons.sensors_off;
    if (rate < 60) return Icons.arrow_downward;
    if (rate > 100) return Icons.arrow_upward;
    return Icons.check_circle;
  }

  @override
  void dispose() {
    characteristicSubscription?.cancel();
    _animationController.dispose();
    _tabController.dispose();
    disconnect();
    db.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkTheme;
    final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardColor = isDark ? const Color(0xFF2D2D2D) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : Colors.black;
    
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.monitor_heart, size: 24),
            SizedBox(width: 8),
            Text(isConnected ? 'Device Connected' : 'VitaTrack Pro'),
          ],
        ),
        backgroundColor: isDark ? Color.fromARGB(255, 93, 101, 122) : Color.fromARGB(255, 90, 96, 105),
        actions: [
          Tooltip(
            message: 'Toggle Theme',
            child: IconButton(
              icon: AnimatedSwitcher(
                duration: Duration(milliseconds: 300),
                child: Icon(
                  isDark ? Icons.light_mode : Icons.dark_mode,
                  key: ValueKey(isDark),
                ),
              ),
              onPressed: widget.onThemeToggle,
            ),
          ),
        ],
      ),
      body: isConnected ? _buildConnectedUI(isDark, bgColor, cardColor, textColor) : _buildScanUI(isDark, bgColor, cardColor),
    );
  }

  Widget _buildScanUI(bool isDark, Color bgColor, Color cardColor) {
    return SingleChildScrollView(
      child: Column(
        children: [
          // Header Section
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(32),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark 
                  ? [Color(0xFF1E3A8A), Color(0xFF3730A3)]
                  : [Color(0xFF3B82F6), Color(0xFF60A5FA)],
              ),
            ),
            child: Column(
              children: [
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Icon(
                    Icons.monitor_heart,
                    size: 64,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'VitaTrack Pro',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Connect your health monitoring device',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          
          // Patient Name Input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Card(
              elevation: 2,
              color: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Patient Information',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        labelText: 'Patient Name',
                        hintText: 'Enter patient name',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.grey.withOpacity(0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Color(0xFF3B82F6),
                            width: 2,
                          ),
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          patientName = value;
                        });
                      },
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(Icons.info, size: 16, color: Colors.grey),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Enter patient name to be included in automatic email reports',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          // Scan Button
          Padding(
            padding: const EdgeInsets.all(20),
            child: AnimatedContainer(
              duration: Duration(milliseconds: 300),
              child: ElevatedButton(
                onPressed: isScanning ? null : startScan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  elevation: 4,
                  shadowColor: Color(0xFF10B981).withOpacity(0.3),
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isScanning)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    else
                      Icon(Icons.search, size: 24),
                    SizedBox(width: 12),
                    Text(
                      isScanning ? 'Scanning for Devices...' : 'Scan for Devices',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          // Devices List
          SizedBox(
            height: 300,
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: 500),
              child: devices.isEmpty
                  ? _buildEmptyState(isDark)
                  : _buildDevicesList(isDark, cardColor),
            ),
          ),
          
          _buildLogsWidget(isDark, cardColor),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.devices_other,
            size: 80,
            color: Colors.grey[400],
          ),
          SizedBox(height: 16),
          Text(
            'No devices found',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Make sure your health monitoring device is turned on and in range',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[500],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevicesList(bool isDark, Color cardColor) {
    return ListView.builder(
      itemCount: devices.length,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemBuilder: (context, index) => AnimatedContainer(
        duration: Duration(milliseconds: 300 + (index * 100)),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Card(
          elevation: 2,
          color: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Color(0xFF3B82F6).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.medical_services, color: Color(0xFF3B82F6)),
            ),
            title: Text(
              devices[index].platformName.isEmpty ? 'Unknown Device' : devices[index].platformName,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              devices[index].remoteId.toString(),
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: Icon(Icons.arrow_forward_ios_rounded, size: 16),
            onTap: () => connectToDevice(devices[index]),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedUI(bool isDark, Color bgColor, Color cardColor, Color textColor) {
    // Calculate dynamic Y-axis ranges for better graph scaling
    final double heartRateMin = heartRateHistory.isEmpty ? 0 : (heartRateHistory.map((e) => e.y).reduce(min) * 0.8);
    final double heartRateMax = heartRateHistory.isEmpty ? 100 : (heartRateHistory.map((e) => e.y).reduce(max) * 1.2);

    return SingleChildScrollView(
      child: Column(
        children: [
          // Welcome Message with Patient Name
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              elevation: 2,
              color: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.person, color: Color(0xFF3B82F6)),
                    SizedBox(width: 12),
                    Text(
                      'Welcome, ${patientName.isEmpty ? 'Patient' : patientName}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Spacer(),
                    // Remove the manual email button
                  ],
                ),
              ),
            ),
          ),
          
          // Heart Rate Card with Pulse Animation
          Padding(
            padding: const EdgeInsets.all(16),
            child: ScaleTransition(
              scale: _pulseAnimation,
              child: Card(
                elevation: 6,
                color: heartAlert ? Color(0xFFDC2626) : cardColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.monitor_heart, size: 32, color: heartAlert ? Colors.white : Color(0xFFEF4444)),
                          SizedBox(width: 12),
                          Text(
                            'HEART RATE',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: heartAlert ? Colors.white : Color(0xFFEF4444),
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: Duration(milliseconds: 500),
                        child: Text(
                          '$heartRate',
                          key: ValueKey(heartRate),
                          style: TextStyle(
                            fontSize: 64,
                            fontWeight: FontWeight.bold,
                            color: heartAlert ? Colors.white : textColor,
                          ),
                        ),
                      ),
                      Text(
                        'BPM',
                        style: TextStyle(
                          fontSize: 16,
                          color: heartAlert ? Colors.white70 : Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: _getHeartRateStatusColor(heartRate).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              _getHeartRateStatusIcon(heartRate),
                              color: _getHeartRateStatusColor(heartRate),
                              size: 16
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _getHeartRateStatus(heartRate),
                              style: TextStyle(
                                color: _getHeartRateStatusColor(heartRate),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Stats Row with Animations
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Temperature Card
                Expanded(
                  child: ScaleTransition(
                    scale: _pulseAnimation,
                    child: Card(
                      elevation: 4,
                      color: tempAlert ? Color(0xFFEA580C) : cardColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Icon(Icons.thermostat, 
                                size: 32, 
                                color: tempAlert ? Colors.white : Color(0xFFF59E0B)),
                            SizedBox(height: 12),
                            AnimatedSwitcher(
                              duration: Duration(milliseconds: 500),
                              child: Text(
                                '${temperature.toStringAsFixed(1)}°',
                                key: ValueKey(temperature),
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: tempAlert ? Colors.white : textColor,
                                ),
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Temperature',
                              style: TextStyle(
                                fontSize: 12,
                                color: tempAlert ? Colors.white70 : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                // Humidity Card
                Expanded(
                  child: ScaleTransition(
                    scale: _pulseAnimation,
                    child: Card(
                      elevation: 4,
                      color: humidityAlert ? Color(0xFF0369A1) : cardColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Icon(Icons.water_drop, 
                                size: 32, 
                                color: humidityAlert ? Colors.white : Color(0xFF0EA5E9)),
                            SizedBox(height: 12),
                            AnimatedSwitcher(
                              duration: Duration(milliseconds: 500),
                              child: Text(
                                '${humidity.toStringAsFixed(1)}%',
                                key: ValueKey(humidity),
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: humidityAlert ? Colors.white : textColor,
                                ),
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Humidity',
                              style: TextStyle(
                                fontSize: 12,
                                color: humidityAlert ? Colors.white70 : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Heart Rate Chart Section
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              elevation: 3,
              color: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.show_chart, color: Color(0xFFEF4444)),
                        SizedBox(width: 8),
                        Text(
                          'Heart Rate Trend',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                        Spacer(),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Color(0xFFEF4444).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Last 10 readings',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFEF4444),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20),
                    SizedBox(
                      height: 200,
                      child: heartRateHistory.isEmpty
                          ? _buildEmptyChartState('Heart Rate')
                          : LineChart(
                              LineChartData(
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: true,
                                  horizontalInterval: (heartRateMax - heartRateMin) / 5,
                                  getDrawingHorizontalLine: (value) {
                                    return FlLine(
                                      color: Colors.grey.withOpacity(0.3),
                                      strokeWidth: 1,
                                    );
                                  },
                                  getDrawingVerticalLine: (value) {
                                    return FlLine(
                                      color: Colors.grey.withOpacity(0.2),
                                      strokeWidth: 1,
                                    );
                                  },
                                ),
                                titlesData: FlTitlesData(
                                  show: true,
                                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 30,
                                      getTitlesWidget: (value, meta) {
                                        if (value.toInt() < heartRateHistory.length) {
                                          return Padding(
                                            padding: const EdgeInsets.only(top: 8.0),
                                            child: Text(
                                              value.toInt().toString(),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey[600],
                                              ),
                                            ),
                                          );
                                        }
                                        return Text('');
                                      },
                                    ),
                                  ),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 40,
                                      getTitlesWidget: (value, meta) {
                                        return Text(
                                          value.toInt().toString(),
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        );
                                      },
                                      interval: (heartRateMax - heartRateMin) / 4,
                                    ),
                                  ),
                                ),
                                borderData: FlBorderData(
                                  show: true,
                                  border: Border.all(
                                    color: Colors.grey.withOpacity(0.3),
                                    width: 1,
                                  ),
                                ),
                                minY: heartRateMin,
                                maxY: heartRateMax,
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: heartRateHistory,
                                    isCurved: true,
                                    color: Color(0xFFEF4444),
                                    barWidth: 4,
                                    isStrokeCapRound: true,
                                    dotData: FlDotData(
                                      show: true,
                                      getDotPainter: (spot, percent, bar, index) {
                                        return FlDotCirclePainter(
                                          radius: 4,
                                          color: Color(0xFFEF4444),
                                          strokeWidth: 2,
                                          strokeColor: Colors.white,
                                        );
                                      },
                                    ),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0xFFEF4444).withOpacity(0.3),
                                          Color(0xFFEF4444).withOpacity(0.1),
                                        ],
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                      ),
                                    ),
                                    gradient: LinearGradient(
                                      colors: [
                                        Color(0xFFEF4444),
                                        Color(0xFFF87171),
                                      ],
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Disconnect Button
          Padding(
            padding: const EdgeInsets.all(16),
            child: AnimatedContainer(
              duration: Duration(milliseconds: 300),
              child: ElevatedButton(
                onPressed: disconnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  elevation: 2,
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bluetooth_disabled, size: 24),
                    SizedBox(width: 12),
                    Text(
                      'Disconnect Device',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          _buildLogsWidget(isDark, cardColor),
        ],
      ),
    );
  }

  Widget _buildEmptyChartState(String chartType) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bar_chart_rounded, size: 48, color: Colors.grey[400]),
          SizedBox(height: 12),
          Text(
            'Waiting for $chartType data...',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 16,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '$chartType data will appear here',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailHistoryWidget(bool isDark, Color cardColor) {
    return Container();// we now use tabs for logs
  }

  Widget _buildLogsWidget(bool isDark, Color cardColor) {
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 2,
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.list_alt_rounded, color: Color(0xFF6B7280)),
            title: Text(
              'Logs',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.clear_all, color: Color(0xFF6B7280)),
                  onPressed: clearLogs,
                  tooltip: 'Clear Logs',
                ),
                IconButton(
                  icon: Icon(
                    logsExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Color(0xFF6B7280),
                  ),
                  onPressed: () => setState(() => logsExpanded = !logsExpanded),
                ),
              ],
            ),
          ),
          if (logsExpanded)
            AnimatedContainer(
              duration: Duration(milliseconds: 300),
              height: 250,
              child: Column(
                children: [
                  // Tab bar for switching between logs
                  TabBar(
                    indicatorColor: Color(0xFF3B82F6),
                    indicatorWeight: 3,
                    labelColor: Color(0xFF3B82F6),
                    unselectedLabelColor: Colors.grey,
                    tabs: [
                      Tab(text: 'System Logs'),
                      Tab(text: 'Email Logs'),
                    ],
                    controller: _tabController,
                  ),
                  // Tab bar view
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        // System Logs
                        _buildSystemLogsView(isDark),
                        // Email Logs
                        _buildEmailLogsView(isDark),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSystemLogsView(bool isDark) {
    return logs.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.list, size: 48, color: Colors.grey[400]),
                SizedBox(height: 12),
                Text(
                  'No system logs yet',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'System events will appear here',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            reverse: true,
            itemCount: logs.length,
            padding: EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (ctx, index) => Container(
              padding: EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: index < logs.length - 1 
                      ? BorderSide(color: Colors.grey.withOpacity(0.1))
                      : BorderSide.none,
                ),
              ),
              child: Text(
                logs[index],
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey[600],
                  fontFamily: 'Monospace',
                ),
              ),
            ),
          );
  }

  Widget _buildEmailLogsView(bool isDark) {
    return emailHistory.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.email_outlined, size: 48, color: Colors.grey[400]),
                SizedBox(height: 12),
                Text(
                  'No email logs yet',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Email reports will appear here',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            reverse: true,
            itemCount: emailHistory.length,
            padding: EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (ctx, index) {
              final email = emailHistory[index];
              return Container(
                padding: EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: index < emailHistory.length - 1 
                        ? BorderSide(color: Colors.grey.withOpacity(0.1))
                        : BorderSide.none,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      email['status'] == 'Sent' 
                          ? Icons.check_circle 
                          : Icons.error,
                      color: email['status'] == 'Sent' 
                          ? Colors.green 
                          : Colors.red,
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            email['timestamp'].toString().split('.')[0],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'To: ${email['recipient']}',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (email['error'] != null)
                            Text(
                              'Error: ${email['error']}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.red,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    Text(
                      email['status'],
                      style: TextStyle(
                        fontSize: 12,
                        color: email['status'] == 'Sent' 
                            ? Colors.green 
                            : Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
  }
}