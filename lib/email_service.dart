import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

class EmailService {
  // List of doctor emails
  static const List<String> doctorEmails = [
    'marvin.bisaso99@gmail.com',
    'ednatakaisa@gmail.com',
    'ayebarecarlton@gmail.com',
    'praiseasiimire38@gmail.com',
  ];

  // Sender email credentials
  static const String senderEmail = 'healthmonitoring56@gmail.com';
  static const String senderPassword = 'utgwavkuzsegbqmi'; 

  // Send email to doctors with patient data
  static Future<bool> sendPatientDataEmail({
    required String patientName,
    required int heartRate,
    required double temperature,
    required double humidity,
    required bool heartAlert,
    required bool tempAlert,
    required bool humidityAlert,
  }) async {
    try {
      // Configure mail server
      final smtpServer = gmail(senderEmail, senderPassword);

      // Create message
      final message = Message()
        ..from = Address(senderEmail, 'Health Monitoring System')
        ..subject = '${heartAlert || tempAlert || humidityAlert ? 'URGENT: ' : ''}Health Data for $patientName'
        ..text = _buildEmailBody(
          patientName: patientName,
          heartRate: heartRate,
          temperature: temperature,
          humidity: humidity,
          heartAlert: heartAlert,
          tempAlert: tempAlert,
          humidityAlert: humidityAlert,
        )
        ..html = _buildEmailHtmlBody(
          patientName: patientName,
          heartRate: heartRate,
          temperature: temperature,
          humidity: humidity,
          heartAlert: heartAlert,
          tempAlert: tempAlert,
          humidityAlert: humidityAlert,
        );

      // Add recipients
      message.bccRecipients.addAll(doctorEmails.map((email) => Address(email)));

      // Send email
      final sendReport = await send(message, smtpServer);
      print('Email sent: ${sendReport.toString()}');
      return true;
    } catch (e) {
      print('Error sending email: $e');
      return false;
    }
  }

  // Build plain text email body
  static String _buildEmailBody({
    required String patientName,
    required int heartRate,
    required double temperature,
    required double humidity,
    required bool heartAlert,
    required bool tempAlert,
    required bool humidityAlert,
  }) {
    final buffer = StringBuffer();
    
    buffer.writeln('Patient Health Data Report');
    buffer.writeln('-------------------------');
    buffer.writeln('Patient: $patientName');
    buffer.writeln('Date: ${DateTime.now().toString()}');
    buffer.writeln('');
    
    buffer.writeln('VITAL SIGNS:');
    buffer.writeln('Heart Rate: $heartRate bpm ${heartAlert ? '(ALERT: Abnormal heart rate)' : ''}');
    buffer.writeln('Temperature: ${temperature.toStringAsFixed(1)}°C ${tempAlert ? '(ALERT: Abnormal temperature)' : ''}');
    buffer.writeln('Humidity: ${humidity.toStringAsFixed(1)}% ${humidityAlert ? '(ALERT: Abnormal humidity)' : ''}');
    buffer.writeln('');
    
    buffer.writeln('RECOMMENDATIONS:');
    buffer.writeln(_getHeartRateRecommendation(heartRate));
    buffer.writeln(_getTemperatureRecommendation(temperature));
    buffer.writeln(_getHumidityRecommendation(humidity));
    buffer.writeln('');
    
    buffer.writeln('This is an automated message from the Health Monitoring System.');
    buffer.writeln('Please take appropriate action if alerts are present.');
    
    return buffer.toString();
  }

  // Build HTML email body
  static String _buildEmailHtmlBody({
    required String patientName,
    required int heartRate,
    required double temperature,
    required double humidity,
    required bool heartAlert,
    required bool tempAlert,
    required bool humidityAlert,
  }) {
    final alertStyle = 'color: red; font-weight: bold;';
    final normalStyle = 'color: green;';
    
    return '''
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background-color: #1E3A8A; color: white; padding: 10px; text-align: center; }
        .vital { margin: 15px 0; padding: 10px; border-left: 4px solid #3B82F6; }
        .alert { ${alertStyle} }
        .normal { ${normalStyle} }
        .recommendations { background-color: #f0f4f8; padding: 15px; margin-top: 20px; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h2>Patient Health Data Report</h2>
        </div>
        
        <h3>Patient: $patientName</h3>
        <p>Date: ${DateTime.now().toString()}</p>
        
        <h3>VITAL SIGNS:</h3>
        
        <div class="vital">
          <strong>Heart Rate:</strong> 
          <span class="${heartAlert ? 'alert' : 'normal'}">
            $heartRate bpm ${heartAlert ? ' ALERT: Abnormal heart rate' : '✓ Normal'}
          </span>
        </div>
        
        <div class="vital">
          <strong>Temperature:</strong> 
          <span class="${tempAlert ? 'alert' : 'normal'}">
            ${temperature.toStringAsFixed(1)}°C ${tempAlert ? ' ALERT: Abnormal temperature' : '✓ Normal'}
          </span>
        </div>
        
        <div class="vital">
          <strong>Humidity:</strong> 
          <span class="${humidityAlert ? 'alert' : 'normal'}">
            ${humidity.toStringAsFixed(1)}% ${humidityAlert ? ' ALERT: Abnormal humidity' : '✓ Normal'}
          </span>
        </div>
        
        <div class="recommendations">
          <h3>RECOMMENDATIONS:</h3>
          <p>${_getHeartRateRecommendation(heartRate)}</p>
          <p>${_getTemperatureRecommendation(temperature)}</p>
          <p>${_getHumidityRecommendation(humidity)}</p>
        </div>
        
        <hr>
        <p><em>This is an automated message from the Health Monitoring System.<br>
        Please take appropriate action if alerts are present.</em></p>
      </div>
    </body>
    </html>
    ''';
  }

  // Get heart rate recommendations
  static String _getHeartRateRecommendation(int heartRate) {
    if (heartRate > 100) {
      return 'Heart rate is elevated. Patient should rest, avoid caffeine and stimulants, and practice deep breathing. If persistent, medical attention may be required.';
    } else if (heartRate < 60) {
      return 'Heart rate is low. Patient should be monitored for symptoms like dizziness or fatigue. If symptomatic, medical attention may be required.';
    } else {
      return 'Heart rate is within normal range. Continue regular monitoring.';
    }
  }

  // Get temperature recommendations
  static String _getTemperatureRecommendation(double temperature) {
    if (temperature > 37.0) {
      return 'Temperature is high. Patient may have fever. Recommend rest, hydration, and fever-reducing medication if appropriate. If temperature exceeds 39.5°C or persists, seek medical attention.';
    } else if (temperature > 36.5) {
      return 'Temperature is slightly elevated. Monitor for other symptoms and ensure adequate hydration.';
    } else if (temperature < 28.0) {
      return 'Temperature is low. Patient should be kept warm and monitored for symptoms of hypothermia.';
    } else {
      return 'Temperature is within normal range (28°C-37°C). Environmental temperature is ${_getEnvironmentalTemperatureRecommendation(temperature)}.';
    }
  }

  // Get environmental temperature recommendations
  static String _getEnvironmentalTemperatureRecommendation(double temperature) {
    if (temperature > 30.0) {
      return 'high - ensure room is well-ventilated, use fans or air conditioning, and stay hydrated';
    } else if (temperature > 25.0) {
      return 'warm - ensure adequate ventilation and hydration';
    } else if (temperature < 18.0) {
      return 'cold - ensure room is adequately heated';
    } else {
      return 'comfortable - maintain current conditions';
    }
  }

  // Get humidity recommendations
  static String _getHumidityRecommendation(double humidity) {
    if (humidity > 60) {
      return 'Humidity is high. High humidity can promote mold growth and may worsen respiratory conditions. Consider using a dehumidifier or improving ventilation.';
    } else if (humidity < 30) {
      return 'Humidity is low. Low humidity can cause dry skin, irritated eyes, and respiratory discomfort. Consider using a humidifier.';
    } else {
      return 'Humidity is within optimal range (30-60%). This is ideal for comfort and respiratory health.';
    }
  }
}