library flutter_iban_scanner;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:iban/iban.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

enum ScreenMode { liveFeed, gallery }

class IBANScannerView extends StatefulWidget {
  final ValueChanged<String> onScannerResult;
  final List<CameraDescription>? cameras;
  final bool allowImagePicker;
  final bool allowCameraSwitch;

  IBANScannerView({
    required this.onScannerResult,
    this.cameras,
    this.allowImagePicker = true,
    this.allowCameraSwitch = true,
  });

  @override
  _IBANScannerViewState createState() => _IBANScannerViewState();
}

class _IBANScannerViewState extends State<IBANScannerView> {
  final TextRecognizer textRecognizer = TextRecognizer();
  ScreenMode _mode = ScreenMode.liveFeed;
  CameraLensDirection initialDirection = CameraLensDirection.back;
  CameraController? _controller;
  File? _image;
  late ImagePicker _imagePicker;
  int _cameraIndex = 0;
  List<CameraDescription> cameras = [];
  bool isBusy = false;
  bool ibanFound = false;
  String iban = "";

  @override
  void initState() {
    super.initState();

    _initScanner();
  }

  void _initScanner() async {
    print('🔍 IBAN Scanner: Initializing scanner...');

    // Önce kamera izni kontrol et
    final cameraStatus = await Permission.camera.status;
    print('📷 Camera permission status: $cameraStatus');

    if (cameraStatus.isDenied) {
      print('⚠️ Camera permission denied, requesting...');
      final result = await Permission.camera.request();
      print('📷 Camera permission request result: ${result.isGranted}');
      if (!result.isGranted) {
        print('❌ Camera permission not granted');
        if (mounted) {
          _showPermissionDeniedDialog();
        }
        return;
      }
    } else if (cameraStatus.isPermanentlyDenied) {
      print('🚫 Camera permission permanently denied');
      if (mounted) {
        _showPermissionDeniedDialog();
      }
      return;
    }

    print('✅ Camera permission granted, getting cameras...');
    cameras = widget.cameras ?? await availableCameras();
    print('📸 Found ${cameras.length} cameras');

    if (cameras.isEmpty) {
      print('❌ No cameras available!');
      return;
    }

    if (initialDirection == CameraLensDirection.front) {
      _cameraIndex = 1;
    }

    print('🎥 Starting live feed with camera index $_cameraIndex...');
    await _startLiveFeed();
    _imagePicker = ImagePicker();

    // Kamera başladıktan sonra UI'ı güncelle
    if (mounted) {
      print('✅ Scanner initialized, updating UI');
      setState(() {});
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Camera Permission Required'),
        content: Text(
          'This app needs camera permission to scan IBANs. Please grant camera permission in your device settings.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop(); // Close scanner screen
            },
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.of(context).pop();
              Navigator.of(context).pop(); // Close scanner screen
            },
            child: Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() async {
    _stopLiveFeed();
    super.dispose();
    await textRecognizer.close();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _body(),
      floatingActionButton: _floatingActionButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget? _floatingActionButton() {
    if (_mode == ScreenMode.gallery) return null;
    if (cameras.length == 1) return null;
    if (widget.allowCameraSwitch == false) return null;
    return Container(
        height: 70.0,
        width: 70.0,
        child: FloatingActionButton(
          child: Icon(
            Platform.isIOS
                ? Icons.flip_camera_ios_outlined
                : Icons.flip_camera_android_outlined,
            size: 40,
          ),
          onPressed: _switchLiveCamera,
        ));
  }

  Widget _body() {
    Widget body;
    if (_mode == ScreenMode.liveFeed)
      body = _liveFeedBody();
    else
      body = _galleryBody();
    return body;
  }

  Widget _liveFeedBody() {
    if (_controller?.value.isInitialized == false || _controller == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                color: Colors.white,
              ),
              SizedBox(height: 20),
              Text(
                'Initializing camera...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_controller != null) CameraPreview(_controller!),
            Mask(),
            Positioned(
              top: 0.0,
              child: SizedBox(
                width: MediaQuery.of(context).size.width,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(left: 20.0, top: 20),
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Icon(Icons.arrow_back),
                      ),
                    ),
                    if (widget.allowImagePicker)
                      Padding(
                        padding: EdgeInsets.only(right: 20.0, top: 20),
                        child: GestureDetector(
                          onTap: _switchScreenMode,
                          child: Icon(
                            _mode == ScreenMode.liveFeed
                                ? Icons.photo_library_outlined
                                : (Platform.isIOS
                                    ? Icons.camera_alt_outlined
                                    : Icons.camera),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  void _switchScreenMode() async {
    if (_mode == ScreenMode.liveFeed) {
      _mode = ScreenMode.gallery;
      await _stopLiveFeed();
    } else {
      _mode = ScreenMode.liveFeed;
      await _startLiveFeed();
    }
    setState(() {});
  }

  Widget _galleryBody() {
    return ListView(shrinkWrap: true, children: [
      _image != null
          ? Container(
              height: 400,
              width: 400,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Image.file(_image!),
                ],
              ),
            )
          : Icon(
              Icons.image,
              size: 200,
            ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: ElevatedButton(
          child: Text('From Gallery'),
          onPressed: () => _getImage(ImageSource.gallery),
        ),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: ElevatedButton(
          child: Text('Take a picture'),
          onPressed: () => _getImage(ImageSource.camera),
        ),
      ),
    ]);
  }

  Future _getImage(ImageSource source) async {
    final pickedFile = await _imagePicker.pickImage(source: source);
    if (pickedFile != null) {
      _processPickedFile(pickedFile);
    } else {
      print('No image selected.');
    }
    setState(() {});
  }

  Future _processPickedFile(XFile pickedFile) async {
    setState(() {
      _image = File(pickedFile.path);
    });
    final inputImage = InputImage.fromFilePath(pickedFile.path);
    processImage(inputImage);
  }

  RegExp regExp = RegExp(
    r"^(.*)(([A-Z]{2}[ \-]?[0-9]{2})(?=(?:[ \-]?[A-Z0-9]){9,30}$)((?:[ \-]?[A-Z0-9]{3,5}){2,7})([ \-]?[A-Z0-9]{1,3})?)$",
    caseSensitive: false,
    multiLine: false,
  );

  Future<void> processImage(InputImage inputImage) async {
    if (isBusy) return;
    if (ibanFound) return; // Zaten IBAN bulunmuş, tekrar işleme
    isBusy = true;

    try {
      final recognisedText = await textRecognizer.processImage(inputImage);
      print('📝 Recognized ${recognisedText.blocks.length} text blocks');

      for (final textBlock in recognisedText.blocks) {
        print('🔍 Text block: ${textBlock.text}');
        if (!regExp.hasMatch(textBlock.text)) {
          continue;
        }
        var possibleIBAN = regExp.firstMatch(textBlock.text)!.group(2).toString();
        print('💳 Possible IBAN found: $possibleIBAN');

        // Remove spaces and dashes for validation
        String cleanIBAN = possibleIBAN.replaceAll(' ', '').replaceAll('-', '');

        if (!isValid(cleanIBAN)) {
          print('❌ IBAN validation failed for: $cleanIBAN');
          continue;
        }

        iban = toPrintFormat(cleanIBAN);
        ibanFound = true;
        print('✅ Valid IBAN found: $iban');

        // Callback'i çağır ve camera stream'i durdur
        await _stopLiveFeed();
        widget.onScannerResult(iban);
        break;
      }
    } catch (e, stackTrace) {
      print('❌ Error processing image: $e');
      print('📋 Stack trace: $stackTrace');
    }

    isBusy = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future _startLiveFeed() async {
    try {
      print('🎬 _startLiveFeed: Getting camera...');
      final camera = cameras[_cameraIndex];
      print('📹 Camera: ${camera.name}, lens direction: ${camera.lensDirection}');

      print('🎥 Creating CameraController...');
      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      print('⏳ Initializing camera controller...');
      await _controller?.initialize();
      print('✅ Camera controller initialized!');

      if (!mounted) {
        print('⚠️ Widget not mounted, stopping...');
        return;
      }

      print('📸 Starting image stream...');
      await _controller?.startImageStream(_processCameraImage);
      print('✅ Image stream started!');

      if (mounted) {
        print('🔄 Updating UI after camera start');
        setState(() {});
      }
    } catch (e, stackTrace) {
      print('❌ Error starting camera: $e');
      print('📋 Stack trace: $stackTrace');
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future _stopLiveFeed() async {
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
  }

  Future _switchLiveCamera() async {
    if (_cameraIndex == 0)
      _cameraIndex = 1;
    else
      _cameraIndex = 0;
    await _stopLiveFeed();
    await _startLiveFeed();
  }

  Future<void> _processCameraImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size imageSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    // iOS ve Android için farklı rotation ve format
    InputImageRotation imageRotation;
    InputImageFormat inputImageFormat;

    if (Platform.isIOS) {
      // iOS için
      imageRotation = InputImageRotation.rotation90deg;
      inputImageFormat = InputImageFormat.bgra8888;
    } else {
      // Android için
      imageRotation = InputImageRotation.rotation90deg;
      inputImageFormat = InputImageFormat.nv21;
    }

    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );

    if (mounted) {
      processImage(inputImage);
    }
  }
}

class Mask extends StatelessWidget {
  const Mask({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color _background = Colors.grey.withOpacity(0.7);

    return SafeArea(
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Container(
                  height: MediaQuery.of(context).size.height - 25,
                  width: 1,
                  color: _background,
                ),
              ),
              Container(
                height: MediaQuery.of(context).size.height - 25,
                width: MediaQuery.of(context).size.width * 0.95,
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: Container(
                        color: _background,
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        border: Border.all(color: Colors.blueAccent),
                      ),
                      height: MediaQuery.of(context).size.width * 0.1,
                      width: MediaQuery.of(context).size.width * 0.95,
                    ),
                    Expanded(
                      child: Container(
                        color: _background,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  height: MediaQuery.of(context).size.height - 25,
                  width: 1,
                  color: _background,
                ),
              ),
            ],
          )
        ],
      ),
    );
  }
}
