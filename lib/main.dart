import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'File Upload & Retrieval',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const FileUploaderScreen(),
    );
  }
}

class FileUploaderScreen extends StatefulWidget {
  const FileUploaderScreen({Key? key}) : super(key: key);

  @override
  State<FileUploaderScreen> createState() => _FileUploaderScreenState();
}

class _FileUploaderScreenState extends State<FileUploaderScreen> {
  // Upload Section
  String? _filePath;
  String _statusMessage = "Select a file to upload.";
  String? _encryptionKey;
  String? _cid;

  // Retrieval Section
  final TextEditingController _cidController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  String _retrievalStatus = "Enter CID and Decryption Key to retrieve file.";

  // Notification setup
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    var initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  // Copy to Clipboard
  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!')),
    );
  }

  // Select File for Upload
  Future<void> _selectFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        setState(() {
          _filePath = result.files.single.path;
          _statusMessage = "File selected: ${result.files.single.name}";
        });
      } else {
        setState(() {
          _statusMessage = "File selection canceled.";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Error selecting file: $e";
      });
    }
  }

  // Encrypt File
  Future<Map<String, String>> _encryptFile(Uint8List fileData) async {
    try {
      final key = encrypt.Key.fromSecureRandom(32); // 256-bit encryption key
      final encrypter =
          encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.ecb));

      final encrypted = encrypter.encryptBytes(fileData);
      setState(() {
        _encryptionKey = base64Encode(key.bytes);
      });

      return {
        'encryptedData': base64Encode(encrypted.bytes),
        'encryptionKey': base64Encode(key.bytes),
      };
    } catch (e) {
      throw Exception("Error encrypting file: $e");
    }
  }

  // Upload to Pinata
  Future<void> _uploadToPinata(String encryptedData, String fileName) async {
    const String apiKey = 'f7b770e84098104f4947';
    const String apiSecret =
        '6ee68dc0a40a9b9094c96f1b354e2ea2844c764e6cb3173dc0df6cb00e6453f1';
    const String url = 'https://api.pinata.cloud/pinning/pinFileToIPFS';

    try {
      final bytes = Uint8List.fromList(utf8.encode(encryptedData));
      final blob =
          http.MultipartFile.fromBytes('file', bytes, filename: fileName);

      final request = http.MultipartRequest('POST', Uri.parse(url))
        ..headers['pinata_api_key'] = apiKey
        ..headers['pinata_secret_api_key'] = apiSecret
        ..files.add(blob);

      final response = await request.send();

      if (response.statusCode == 200) {
        final responseBody = await response.stream.bytesToString();
        final responseJson = jsonDecode(responseBody);
        setState(() {
          _cid = responseJson['IpfsHash'];
          _statusMessage = "File uploaded successfully to Pinata!";
        });
      } else {
        throw Exception("Failed to upload file: ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Error uploading file: $e";
      });
    }
  }

  // Handle File Upload
  Future<void> _handleFileUpload() async {
    if (_filePath == null) {
      setState(() {
        _statusMessage = "Please select a file first.";
      });
      return;
    }

    try {
      setState(() {
        _statusMessage = "Encrypting file...";
      });

      final fileBytes = await File(_filePath!).readAsBytes();
      final encryptionResult = await _encryptFile(fileBytes);

      setState(() {
        _statusMessage = "Uploading to Pinata...";
      });

      await _uploadToPinata(
          encryptionResult['encryptedData']!, _filePath!.split('/').last);
    } catch (e) {
      setState(() {
        _statusMessage = "Error: $e";
      });
    }
  }

  // Retrieve File from Pinata
  Future<void> _retrieveFile() async {
    final cid = _cidController.text.trim();
    final keyString = _keyController.text.trim();

    if (cid.isEmpty || keyString.isEmpty) {
      setState(() {
        _retrievalStatus = "CID and Decryption Key cannot be empty.";
      });
      return;
    }

    try {
      setState(() {
        _retrievalStatus = "Fetching file from Pinata...";
      });

      // Fetch encrypted data from Pinata
      final url = 'https://gateway.pinata.cloud/ipfs/$cid';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        // Decode the encrypted data
        final encryptedBytes = base64Decode(response.body);

        // Decode the encryption key
        final key = encrypt.Key(base64Decode(keyString));

        // Initialize the encrypter
        final encrypter =
            encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.ecb));

        // Decrypt the data
        final decryptedBytes =
            encrypter.decryptBytes(encrypt.Encrypted(encryptedBytes));

        // Ensure the directory exists
        final directory = await getExternalStorageDirectory();
        final downloadDirectory = Directory('${directory!.path}/Download');
        if (!await downloadDirectory.exists()) {
          await downloadDirectory.create(recursive: true);
        }

        // Save the file locally in the Download folder
        final filePath = '${downloadDirectory.path}/retrieved_file';
        final file = File(filePath);

        await file.writeAsBytes(decryptedBytes);

        setState(() {
          _retrievalStatus =
              "File retrieved successfully! Saved at: ${file.path}";
        });

        // Show notification for file download
        _showDownloadNotification(file.path);
      } else {
        throw Exception(
            "Failed to fetch file from Pinata. HTTP Status: ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        _retrievalStatus = "Error retrieving file: $e";
      });
    }
  }

  // Show notification after file is saved
  Future<void> _showDownloadNotification(String filePath) async {
    var androidDetails = AndroidNotificationDetails(
      'download_channel',
      'Download Notifications',
      channelDescription: 'Notifications for downloaded files',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    var notificationDetails = NotificationDetails(android: androidDetails);

    await flutterLocalNotificationsPlugin.show(
      0,
      'File Downloaded',
      'File has been saved to your device: $filePath',
      notificationDetails,
      payload: filePath,
    );
  }

  // Open file when notification is tapped
  Future<void> _onNotificationTapped(String filePath) async {
    if (await canLaunch(filePath)) {
      await launch(filePath);
    } else {
      throw 'Could not open file: $filePath';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Upload & Retrieval'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Upload Section
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.deepPurple, width: 2.0),
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Column(
                children: [
                  ElevatedButton(
                    onPressed: _selectFile,
                    child: const Text("Select File"),
                  ),
                  if (_filePath != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text("Selected File: $_filePath"),
                    ),
                  ElevatedButton(
                    onPressed: _handleFileUpload,
                    child: const Text("Upload File"),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(_statusMessage),
                  ),
                  if (_cid != null)
                    Column(
                      children: [
                        GestureDetector(
                          onTap: () => _copyToClipboard(_cid!, "CID"),
                          child: Text(
                            "CID: $_cid",
                            style: TextStyle(
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                        if (_encryptionKey != null)
                          GestureDetector(
                            onTap: () => _copyToClipboard(
                                _encryptionKey!, "Encryption Key"),
                            child: Text(
                              "Encryption Key: $_encryptionKey",
                              style: TextStyle(
                                color: Colors.green,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16.0),

            // Retrieval Section
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.deepPurple, width: 2.0),
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Column(
                children: [
                  const Text(
                    "Retrieve File",
                    style:
                        TextStyle(fontSize: 20.0, fontWeight: FontWeight.bold),
                  ),
                  TextField(
                    controller: _cidController,
                    decoration: const InputDecoration(labelText: "CID"),
                  ),
                  TextField(
                    controller: _keyController,
                    decoration:
                        const InputDecoration(labelText: "Decryption Key"),
                  ),
                  ElevatedButton(
                    onPressed: _retrieveFile,
                    child: const Text("Retrieve File"),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(_retrievalStatus),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
