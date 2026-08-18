import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:encrypt/encrypt.dart' as encrypt_pkg;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Camera Init Error: $e");
  }
  runApp(const SecureVaultApp());
}

// ============================================================================
// 1. التطبيق الأساسي ونظام القفل
// ============================================================================
class SecureVaultApp extends StatelessWidget {
  const SecureVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SecurePhoto Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        primaryColor: const Color(0xFF6C63FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: const AppLockScreen(),
    );
  }
}

class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _pinController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  String _errorMessage = '';
  bool _isFirstRun = false;

  @override
  void initState() {
    super.initState();
    _applySecurityFlags();
    _checkPinStatus();
  }

  Future<void> _applySecurityFlags() async {
    if (Platform.isAndroid) {
      await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
    }
  }

  Future<void> _checkPinStatus() async {
    String? pin = await _storage.read(key: 'user_pin');
    if (pin == null) {
      setState(() => _isFirstRun = true);
    }
  }

  Future<void> _verifyOrSetPin() async {
    final inputPin = _pinController.text.trim();
    if (inputPin.length < 4) {
      setState(() => _errorMessage = 'أدخل 4 أرقام على الأقل');
      return;
    }

    if (_isFirstRun) {
      await _storage.write(key: 'user_pin', value: inputPin);
      _navigateToMain();
    } else {
      String? savedPin = await _storage.read(key: 'user_pin');
      if (inputPin == savedPin) {
        _navigateToMain();
      } else {
        setState(() => _errorMessage = 'رمز PIN غير صحيح');
        _pinController.clear();
      }
    }
  }

  void _navigateToMain() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.security, size: 80, color: Color(0xFF6C63FF)),
            const SizedBox(height: 20),
            Text(
              _isFirstRun ? 'تعيين رمز PIN للخزنة' : 'أدخل رمز PIN للدخول',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '••••',
              ),
            ),
            if (_errorMessage.isNotEmpty)
              Text(_errorMessage, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                minimumSize: const Size(double.infinity, 50),
              ),
              onPressed: _verifyOrSetPin,
              child: Text(_isFirstRun ? 'حفظ ودخول' : 'فتح الخزنة'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 2. الشاشة الرئيسية والقيادة
// ============================================================================
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final _secureStorage = const FlutterSecureStorage();
  encrypt_pkg.Encrypter? _encrypter;
  encrypt_pkg.IV? _iv;
  bool _isCryptoReady = false;

  @override
  void initState() {
    super.initState();
    _initCryptoKeys();
  }

  Future<void> _initCryptoKeys() async {
    String? storedKey = await _secureStorage.read(key: 'master_key');
    if (storedKey == null) {
      final key = encrypt_pkg.Key.fromSecureRandom(32);
      await _secureStorage.write(key: 'master_key', value: key.base64);
      storedKey = key.base64;
    }
    final key = encrypt_pkg.Key.fromBase64(storedKey);
    _iv = encrypt_pkg.IV.fromLength(16);
    _encrypter = encrypt_pkg.Encrypter(encrypt_pkg.AES(key));

    setState(() => _isCryptoReady = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCryptoReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final screens = [
      CameraView(encrypter: _encrypter!, iv: _iv!),
      GalleryView(encrypter: _encrypter!, iv: _iv!),
      const SettingsView(),
    ];

    return Scaffold(
      body: screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: const Color(0xFF6C63FF),
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFF1A1A1A),
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.camera_alt), label: 'الكاميرا'),
          BottomNavigationBarItem(icon: Icon(Icons.photo_library), label: 'المعرض'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'الإعدادات'),
        ],
      ),
    );
  }
}

// ============================================================================
// 3. الكاميرا والتشفير المباشر في الذاكرة
// ============================================================================
class CameraView extends StatefulWidget {
  final encrypt_pkg.Encrypter encrypter;
  final encrypt_pkg.IV iv;

  const CameraView({super.key, required this.encrypter, required this.iv});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _showGrid = false;
  FlashMode _flashMode = FlashMode.off;
  double _zoomLevel = 1.0;
  int _timerSeconds = 0;
  bool _isCountingDown = false;
  int _countdownValue = 0;

  @override
  void initState() {
    super.initState();
    _setupCamera();
  }

  Future<void> _setupCamera() async {
    await Permission.camera.request();
    if (cameras.isEmpty) return;

    _controller = CameraController(cameras[0], ResolutionPreset.high, enableAudio: false);
    await _controller!.initialize();
    if (!mounted) return;
    setState(() => _isInitialized = true);
  }

  Future<void> _capturePhoto() async {
    if (!_controller!.value.isInitialized) return;

    if (_timerSeconds > 0) {
      setState(() {
        _isCountingDown = true;
        _countdownValue = _timerSeconds;
      });
      for (int i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdownValue = i);
        await Future.delayed(const Duration(seconds: 1));
      }
      setState(() => _isCountingDown = false);
    }

    final XFile file = await _controller!.takePicture();
    final Uint8List rawBytes = await file.readAsBytes();

    // حذف ملف الكاميرا المؤقت فوراً من التخزين
    await File(file.path).delete();

    // تشفير مصفوفة البايت داخل الذاكرة RAM
    final encryptedData = widget.encrypter.encryptBytes(rawBytes, iv: widget.iv);

    // كتابة الملف المشفر فقط بصيغة .spv
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'vault'));
    if (!await vaultDir.exists()) await vaultDir.create();

    final filePath = p.join(vaultDir.path, 'IMG_${DateTime.now().millisecondsSinceEpoch}.spv');
    await File(filePath).writeAsBytes(encryptedData.bytes);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم التشفير والحفظ مباشرة في الذاكرة')),
      );
    }
  }

  void _toggleFlash() {
    setState(() {
      _flashMode = _flashMode == FlashMode.off ? FlashMode.always : FlashMode.off;
      _controller?.setFlashMode(_flashMode);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      body: Stack(
        children: [
          CameraPreview(_controller!),
          if (_showGrid) const GridOverlay(),
          if (_isCountingDown)
            Center(
              child: Text(
                '$_countdownValue',
                style: const TextStyle(fontSize: 96, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          Positioned(
            top: 40,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(_flashMode == FlashMode.off ? Icons.flash_off : Icons.flash_on),
                  color: Colors.white,
                  onPressed: _toggleFlash,
                ),
                IconButton(
                  icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off),
                  color: Colors.white,
                  onPressed: () => setState(() => _showGrid = !_showGrid),
                ),
                DropdownButton<int>(
                  value: _timerSeconds,
                  dropdownColor: Colors.black87,
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('بدون مؤقت')),
                    DropdownMenuItem(value: 3, child: Text('3 ثوانٍ')),
                    DropdownMenuItem(value: 5, child: Text('5 ثوانٍ')),
                  ],
                  onChanged: (val) => setState(() => _timerSeconds = val ?? 0),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 100,
            left: 30,
            right: 30,
            child: Slider(
              value: _zoomLevel,
              min: 1.0,
              max: 4.0,
              activeColor: const Color(0xFF6C63FF),
              onChanged: (val) {
                setState(() => _zoomLevel = val);
                _controller?.setZoomLevel(val);
              },
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 25.0),
              child: FloatingActionButton(
                backgroundColor: const Color(0xFF6C63FF),
                onPressed: _capturePhoto,
                child: const Icon(Icons.camera, size: 32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GridOverlay extends StatelessWidget {
  const GridOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: Row(children: [Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24))))])),
        Expanded(child: Row(children: [Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24))))])),
        Expanded(child: Row(children: [Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24)))), Expanded(child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white24))))])),
      ],
    );
  }
}

// ============================================================================
// 4. المعرض ومحرر الصور المباشر في الذاكرة RAM
// ============================================================================
class GalleryView extends StatefulWidget {
  final encrypt_pkg.Encrypter encrypter;
  final encrypt_pkg.IV iv;

  const GalleryView({super.key, required this.encrypter, required this.iv});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  List<FileSystemEntity> _files = [];

  @override
  void initState() {
    super.initState();
    _loadVaultFiles();
  }

  Future<void> _loadVaultFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'vault'));
    if (await vaultDir.exists()) {
      setState(() {
        _files = vaultDir.listSync().where((f) => f.path.endsWith('.spv')).toList();
      });
    }
  }

  Future<Uint8List> _decryptImage(File file) async {
    final encryptedBytes = await file.readAsBytes();
    final encrypted = encrypt_pkg.Encrypted(encryptedBytes);
    return Uint8List.fromList(widget.encrypter.decryptBytes(encrypted, iv: widget.iv));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الخزنة المشفرة'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadVaultFiles),
        ],
      ),
      body: _files.isEmpty
          ? const Center(child: Text('لا توجد صور مشفرة'))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = File(_files[index].path);
                return FutureBuilder<Uint8List>(
                  future: _decryptImage(file),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PhotoDetailViewer(
                                imageBytes: snapshot.data!,
                                filePath: file.path,
                                encrypter: widget.encrypter,
                                iv: widget.iv,
                                onDelete: () {
                                  file.deleteSync();
                                  _loadVaultFiles();
                                  Navigator.pop(context);
                                },
                              ),
                            ),
                          );
                        },
                        child: Image.memory(snapshot.data!, fit: BoxFit.cover),
                      );
                    }
                    return Container(
                      color: Colors.grey[900],
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  },
                );
              },
            ),
    );
  }
}

// عارض الصورة ومحرر التعديلات بالذاكرة
class PhotoDetailViewer extends StatefulWidget {
  final Uint8List imageBytes;
  final String filePath;
  final encrypt_pkg.Encrypter encrypter;
  final encrypt_pkg.IV iv;
  final VoidCallback onDelete;

  const PhotoDetailViewer({
    super.key,
    required this.imageBytes,
    required this.filePath,
    required this.encrypter,
    required this.iv,
    required this.onDelete,
  });

  @override
  State<PhotoDetailViewer> createState() => _PhotoDetailViewerState();
}

class _PhotoDetailViewerState extends State<PhotoDetailViewer> {
  late Uint8List _currentBytes;

  @override
  void initState() {
    super.initState();
    _currentBytes = widget.imageBytes;
  }

  Future<void> _applyFilterAndSave(String filterType) async {
    img.Image? decoded = img.decodeImage(_currentBytes);
    if (decoded == null) return;

    if (filterType == 'BW') {
      decoded = img.grayscale(decoded);
    } else if (filterType == 'SEPIA') {
      decoded = img.sepia(decoded);
    } else if (filterType == 'ROTATE') {
      decoded = img.copyRotate(decoded, angle: 90);
    }

    final newPngBytes = Uint8List.fromList(img.encodePng(decoded));
    final encryptedData = widget.encrypter.encryptBytes(newPngBytes, iv: widget.iv);

    await File(widget.filePath).writeAsBytes(encryptedData.bytes);

    setState(() {
      _currentBytes = newPngBytes;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم التعديل وإعادة التشفير بالذاكرة')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: widget.onDelete),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              child: Image.memory(_currentBytes),
            ),
          ),
          Container(
            color: const Color(0xFF1A1A1A),
            height: 70,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: () => _applyFilterAndSave('BW'), child: const Text('أبيض/أسود')),
                ElevatedButton(onPressed: () => _applyFilterAndSave('SEPIA'), child: const Text('سيبيا')),
                ElevatedButton(onPressed: () => _applyFilterAndSave('ROTATE'), child: const Text('تدوير 90°')),
              ],
            ),
          )
        ],
      ),
    );
  }
}

// ============================================================================
// 5. الإعدادات وتصدير ZIP والحذف الكلي
// ============================================================================
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String _stats = 'جاري الحساب...';

  @override
  void initState() {
    super.initState();
    _calculateStats();
  }

  Future<void> _calculateStats() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'vault'));
    if (await vaultDir.exists()) {
      final files = vaultDir.listSync().where((f) => f.path.endsWith('.spv')).toList();
      int totalSize = 0;
      for (var f in files) {
        totalSize += (await f.stat()).size;
      }
      final sizeMB = (totalSize / (1024 * 1024)).toStringAsFixed(2);
      setState(() {
        _stats = 'عدد الصور: ${files.length} | الحجم: $sizeMB ميجابايت';
      });
    } else {
      setState(() => _stats = 'الخزنة فارغة');
    }
  }

  Future<void> _exportToZip() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'vault'));
    if (!await vaultDir.exists()) return;

    final archive = Archive();
    final files = vaultDir.listSync().where((f) => f.path.endsWith('.spv'));

    for (var fileEntity in files) {
      final file = File(fileEntity.path);
      final bytes = await file.readAsBytes();
      final filename = p.basename(fileEntity.path);
      archive.addFile(ArchiveFile(filename, bytes.length, bytes));
    }

    final zipEncoder = ZipEncoder();
    final zipBytes = zipEncoder.encode(archive);
    if (zipBytes == null) return;

    final zipPath = p.join(dir.path, 'Vault_Backup.zip');
    await File(zipPath).writeAsBytes(zipBytes);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم تصدير النسخة الاحتياطية:\n$zipPath')),
      );
    }
  }

  Future<void> _wipeData() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(dir.path, 'vault'));
    if (await vaultDir.exists()) {
      await vaultDir.delete(recursive: true);
    }
    _calculateStats();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات والأمان'), backgroundColor: const Color(0xFF1A1A1A)),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            ListTile(
              tileColor: const Color(0xFF1A1A1A),
              title: const Text('إحصائيات الخزنة'),
              subtitle: Text(_stats, style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                minimumSize: const Size(double.infinity, 50),
              ),
              icon: const Icon(Icons.archive),
              label: const Text('تصدير الصور المشفرة إلى ZIP'),
              onPressed: _exportToZip,
            ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size(double.infinity, 50),
              ),
              icon: const Icon(Icons.delete_forever),
              label: const Text('التدمير الذاتي (مسح الخزنة بالكامل)'),
              onPressed: _wipeData,
            ),
          ],
        ),
      ),
    );
  }
}
