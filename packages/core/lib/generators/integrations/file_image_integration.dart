import 'dart:io';

import 'package:flutter_gen_core/generators/integrations/integration.dart';
import 'package:image_size_getter/file_input.dart';
import 'package:image_size_getter/image_size_getter.dart';

/// The main image integration, supporting all image asset types. See
/// [isSupport] for the exact supported mime types.
///
/// This integration is by enabled by default.
class FileImageIntegration extends Integration {
  FileImageIntegration(
    String packageName, {
    super.parseMetadata,
  }) : super(packageName);

  String get packageParameter => isPackage ? ' = package' : '';

  String get keyName =>
      isPackage ? "'packages/$packageName/\$_assetName'" : '_assetName';

  @override
  List<Import> get requiredImports => const [
        Import('package:flutter/widgets.dart'),
        Import('dart:io'),
      ];

  @override
  String get classOutput => _classDefinition;

  String get _classDefinition => '''class FileAssetGenImage {
  const FileAssetGenImage(
    this._filePath, {
    this.size,
    this.flavors = const {},
  });

  final String _filePath;

${isPackage ? "\n  static const String package = '$packageName';" : ''}

  final Size? size;
  final Set<String> flavors;

  Image image({
    Key? key,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
    String? semanticLabel,
    bool excludeFromSemantics = false,
    double? scale,
    double? width,
    double? height,
    Color? color,
    Animation<double>? opacity,
    BlendMode? colorBlendMode,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    ImageRepeat repeat = ImageRepeat.noRepeat,
    Rect? centerSlice,
    bool matchTextDirection = false,
    bool gaplessPlayback = true,
    bool isAntiAlias = false,
    FilterQuality filterQuality = FilterQuality.medium,
    int? cacheWidth,
    int? cacheHeight,
  }) {
    return Image.file(
      File( _filePath),
      key: key,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      scale: scale ?? 1.0,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      isAntiAlias: isAntiAlias,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }

  ImageProvider provider() {
      return FileImage(File(_filePath));
  }

  String get path => _filePath;

  String get keyName => _filePath;
}
''';

  @override
  String get className => 'FileAssetGenImage';

  @override
  String classInstantiate(AssetType asset) {
    final info = parseMetadata ? _getMetadata(asset) : null;
    final buffer = StringBuffer(className);
    buffer.write('(');
    buffer.write('\'${asset.posixStylePath}\'');
    if (info != null) {
      buffer.write(', size: Size(${info.width}, ${info.height})');
    }
    if (asset.flavors.isNotEmpty) {
      buffer.write(', flavors: {');
      final flavors = asset.flavors.map((e) => '\'$e\'').join(', ');
      buffer.write(flavors);
      buffer.write('}');
      buffer.write(','); // Better formatting.
    }
    buffer.write(')');
    return buffer.toString();
  }

  @override
  bool isSupport(AssetType asset) {
    /// Flutter official supported image types. See
    /// https://api.flutter.dev/flutter/widgets/Image-class.html
    switch (asset.mime) {
      case 'image/jpeg':
      case 'image/png':
      case 'image/gif':
      case 'image/bmp':
      case 'image/vnd.wap.wbmp':
      case 'image/webp':
        return true;
      default:
        return false;
    }
  }

  @override
  bool get isConstConstructor => true;

  /// Extract metadata from the asset.
  ImageMetadata? _getMetadata(AssetType asset) {
    try {
      final result = ImageSizeGetter.getSizeResult(
        FileInput(File(asset.fullPath)),
      );
      final size = result.size;
      return ImageMetadata(size.width.toDouble(), size.height.toDouble());
    } catch (e) {
      stderr
          .writeln('[WARNING] Failed to parse \'${asset.path}\' metadata: $e');
    }
    return null;
  }
}
