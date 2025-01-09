import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

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
  const FileUploaderScreen({super.key});

  @override
  State<FileUploaderScreen> createState() => _FileUploaderScreenState();
}

class _FileUploaderScreenState extends State<FileUploaderScreen> {
  String? _filePath;
  String _statusMessage = "Select a file to upload.";
  String? _encryptionKey;
  String? _cid;

  final TextEditingController _cidController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  String _retrievalStatus = "Enter CID and Decryption Key to retrieve file.";

  Future<void> _requestStoragePermission() async {
    if (!await Permission.storage.isGranted) {
      await Permission.storage.request();
    }
  }

  Future<String> _getDownloadDirectory() async {
    final directory = await getExternalStorageDirectory();
    return '${directory!.path}/Download';
  }

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

  Future<Map<String, dynamic>> _encryptFile(Uint8List fileData) async {
    final key = encrypt.Key.fromSecureRandom(32); // 256-bit key
    final encrypter =
        encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    final iv = encrypt.IV.fromSecureRandom(16);

    final encrypted = encrypter.encryptBytes(fileData, iv: iv);

    setState(() {
      _encryptionKey = base64Encode(key.bytes + iv.bytes);
    });

    return {
      'encryptedData': Uint8List.fromList(encrypted.bytes),
      'encryptionKey': key.bytes,
      'iv': iv.bytes,
    };
  }

  Future<void> _uploadToPinata(Uint8List encryptedData, String fileName) async {
    const String apiKey = 'f7b770e84098104f4947';
    const String apiSecret =
        '6ee68dc0a40a9b9094c96f1b354e2ea2844c764e6cb3173dc0df6cb00e6453f1';
    const String url = 'https://api.pinata.cloud/pinning/pinFileToIPFS';

    try {
      final request = http.MultipartRequest('POST', Uri.parse(url))
        ..headers['pinata_api_key'] = apiKey
        ..headers['pinata_secret_api_key'] = apiSecret
        ..files.add(
          http.MultipartFile.fromBytes('file', encryptedData,
              filename: fileName),
        );

      final response = await request.send();

      if (response.statusCode == 200) {
        final responseBody = await response.stream.bytesToString();
        final responseJson = jsonDecode(responseBody);
        setState(() {
          _cid = responseJson['IpfsHash'];
          _statusMessage = "File uploaded successfully!";
        });
      } else {
        setState(() {
          _statusMessage = "Failed to upload file: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Error uploading file: $e";
      });
    }
  }

  Future<void> _handleFileUpload() async {
    try {
      await _requestStoragePermission();

      if (_filePath == null) {
        setState(() {
          _statusMessage = "Please select a file first.";
        });
        return;
      }

      setState(() {
        _statusMessage = "Encrypting file...";
      });

      final fileBytes = await File(_filePath!).readAsBytes();
      final encryptionResult = await _encryptFile(fileBytes);

      setState(() {
        _statusMessage = "Uploading to Pinata...";
      });

      await _uploadToPinata(
        encryptionResult['encryptedData']!,
        _filePath!.split('/').last,
      );
    } catch (e) {
      setState(() {
        _statusMessage = "Error: $e";
      });
    }
  }

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
      await _requestStoragePermission();
      setState(() {
        _retrievalStatus = "Fetching file from Pinata...";
      });

      final url = 'https://gateway.pinata.cloud/ipfs/$cid';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final encryptedBytes = response.bodyBytes;

        final decodedKey = base64Decode(keyString);
        final key = encrypt.Key(decodedKey.sublist(0, 32));
        final iv = encrypt.IV(decodedKey.sublist(32, 48));
        final encrypter =
            encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
        final decryptedBytes =
            encrypter.decryptBytes(encrypt.Encrypted(encryptedBytes), iv: iv);

        final downloadPath = await _getDownloadDirectory();
        final filePath = '$downloadPath/retrieved_file';

        final file = File(filePath);
        await file.create(recursive: true);
        await file.writeAsBytes(decryptedBytes);

        setState(() {
          _retrievalStatus = "File retrieved successfully! Saved to Downloads.";
        });
      } else {
        setState(() {
          _retrievalStatus = "Failed to fetch file: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _retrievalStatus = "Error retrieving file: $e";
      });
    }
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$text copied to clipboard!')),
    );
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
                    GestureDetector(
                      onTap: () => _copyToClipboard(_cid!),
                      child: Text(
                        "CID: $_cid",
                        style: const TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  if (_encryptionKey != null)
                    GestureDetector(
                      onTap: () => _copyToClipboard(_encryptionKey!),
                      child: Text(
                        "Encryption Key: $_encryptionKey",
                        style: const TextStyle(
                          color: Colors.green,
                          decoration: TextDecoration.underline,
                        ),
                      ),
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
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: TextField(
                      controller: _cidController,
                      decoration: const InputDecoration(
                        labelText: "Enter CID",
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: TextField(
                      controller: _keyController,
                      decoration: const InputDecoration(
                        labelText: "Enter Decryption Key",
                      ),
                    ),
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
