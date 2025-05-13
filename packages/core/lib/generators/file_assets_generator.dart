import 'dart:collection';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dartx/dartx.dart' hide IterableSorted;
import 'package:flutter_gen_core/generators/generator_helper.dart';
import 'package:flutter_gen_core/generators/integrations/image_integration.dart';
import 'package:flutter_gen_core/generators/integrations/integration.dart';
import 'package:flutter_gen_core/generators/integrations/lottie_integration.dart';
import 'package:flutter_gen_core/generators/integrations/rive_integration.dart';
import 'package:flutter_gen_core/generators/integrations/svg_integration.dart';
import 'package:flutter_gen_core/settings/config.dart';
import 'package:flutter_gen_core/settings/flavored_asset.dart';
import 'package:flutter_gen_core/settings/pubspec.dart';
import 'package:flutter_gen_core/utils/string.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart';

class FileAssetsGenConfig {
  FileAssetsGenConfig._(
    this.input,
    this._packageName,
    this.flutterGen,
    this.assets,
    this.exclude,
  );

  factory FileAssetsGenConfig.fromConfig(File pubspecFile, Config config) {
    return FileAssetsGenConfig._(
      config.pubspec.flutterGen.file!.input,
      config.pubspec.packageName,
      config.pubspec.flutterGen,
      config.pubspec.flutter.assets,
      config.pubspec.flutterGen.assets.exclude.map(Glob.new).toList(),
    );
  }

  final String input;
  final String _packageName;
  final FlutterGen flutterGen;
  final List<Object> assets;
  final List<Glob> exclude;

  String get packageParameterLiteral =>
      flutterGen.assets.outputs.packageParameterEnabled ? _packageName : '';
}

Future<String> generateFileAssets(
  FileAssetsGenConfig config,
  DartFormatter formatter,
) async {
  final integrations = <Integration>[
    if (config.flutterGen.integrations.image)
      ImageIntegration(
        config.packageParameterLiteral,
        parseMetadata: config.flutterGen.parseMetadata,
      ),
    if (config.flutterGen.integrations.flutterSvg)
      SvgIntegration(
        config.packageParameterLiteral,
        parseMetadata: config.flutterGen.parseMetadata,
      ),
    if (config.flutterGen.integrations.rive)
      RiveIntegration(
        config.packageParameterLiteral,
      ),
    if (config.flutterGen.integrations.lottie)
      LottieIntegration(
        config.packageParameterLiteral,
      ),
  ];

  final classesBuffer = StringBuffer();
  final _StyleDefinition definition;
  switch (config.flutterGen.assets.outputs.style) {
    case FlutterGenElementAssetsOutputsStyle.dotDelimiterStyle:
      definition = _dotDelimiterStyleDefinition;
      break;
    case FlutterGenElementAssetsOutputsStyle.snakeCaseStyle:
      definition = _snakeCaseStyleDefinition;
      break;
    case FlutterGenElementAssetsOutputsStyle.camelCaseStyle:
      definition = _camelCaseStyleDefinition;
      break;
  }
  classesBuffer.writeln(await definition(config, integrations));

  final imports = <Import>{};
  for (final integration in integrations.where((e) => e.isEnabled)) {
    imports.addAll(integration.requiredImports);
    classesBuffer.writeln(integration.classOutput);
  }

  final importsBuffer = StringBuffer();
  for (final e in imports.sorted((a, b) => a.import.compareTo(b.import))) {
    importsBuffer.writeln(import(e));
  }

  final buffer = StringBuffer();
  buffer.writeln(header);
  buffer.writeln(ignore);
  buffer.writeln(importsBuffer.toString());
  buffer.writeln(classesBuffer.toString());
  return formatter.format(buffer.toString());
}

String? generatePackageNameForConfig(FileAssetsGenConfig config) {
  if (config.flutterGen.assets.outputs.packageParameterEnabled) {
    return config._packageName;
  } else {
    return null;
  }
}

/// Returns a list of all relative path assets that are to be considered.
List<FlavoredAsset> _getAssetRelativePathList(
  /// The absolute root path of the assets directory.
  String rootPath,

  /// List of globs as provided the `flutter_gen -> assets -> exclude`
  /// section in the pubspec.yaml.
  List<Glob> excludes,
) {
  final assetRelativePathList = <FlavoredAsset>[];

  void traverseDirectory(Directory directory, String flavor) {
    final entities = directory.listSync();
    for (final entity in entities) {
      if (entity is Directory) {
        traverseDirectory(entity, flavor);
      } else if (entity is File) {
        final relativePath = relative(entity.path, from: rootPath);
        final asset = FlavoredAsset(path: relativePath, flavors: {flavor});
        assetRelativePathList.add(asset);
      }
    }
  }

  // 假设每个子目录名都是一个 flavor
  final rootDir = Directory(rootPath);
  final children = rootDir.listSync();
  for (final child in children) {
    if (child is Directory) {
      final flavor = basename(child.path);
      traverseDirectory(child, flavor);
    }
  }

  if (excludes.isEmpty) {
    return assetRelativePathList;
  }
  return assetRelativePathList
      .where((asset) => !excludes.any((exclude) => exclude.matches(asset.path)))
      .toList();
}

AssetType _constructAssetTree(
  List<FlavoredAsset> assetRelativePathList,
  String rootPath,
) {
  // Relative path is the key
  final assetTypeMap = <String, AssetType>{
    '.': AssetType(rootPath: rootPath, path: '.', flavors: {}),
  };
  for (final asset in assetRelativePathList) {
    String path = asset.path;
    while (path != '.') {
      assetTypeMap.putIfAbsent(
        path,
        () => AssetType(rootPath: rootPath, path: path, flavors: asset.flavors),
      );
      path = dirname(path);
    }
  }
  // Construct the AssetType tree
  for (final assetType in assetTypeMap.values) {
    if (assetType.path == '.') {
      continue;
    }
    final parentPath = dirname(assetType.path);
    assetTypeMap[parentPath]?.addChild(assetType);
  }
  return assetTypeMap['.']!;
}

Future<_Statement?> _createAssetTypeStatement(
  FileAssetsGenConfig config,
  UniqueAssetType assetType,
  List<Integration> integrations,
) async {
  final childAssetAbsolutePath = join(config.input, assetType.path);
  if (FileSystemEntity.isDirectorySync(childAssetAbsolutePath)) {
    final childClassName = '\$${assetType.path.camelCase().capitalize()}Gen';
    return _Statement(
      type: childClassName,
      filePath: assetType.posixStylePath,
      name: assetType.name,
      value: '$childClassName()',
      isConstConstructor: true,
      isDirectory: true,
      needDartDoc: false,
    );
  } else if (!assetType.isIgnoreFile) {
    Integration? integration;
    for (final element in integrations) {
      final call = element.isSupport(assetType);
      final bool isSupport;
      if (call is Future<bool>) {
        isSupport = await call;
      } else {
        isSupport = call;
      }
      if (isSupport) {
        integration = element;
        break;
      }
    }
    if (integration == null) {
      var assetKey = assetType.posixStylePath;
      if (config.flutterGen.assets.outputs.packageParameterEnabled) {
        assetKey = 'packages/${config._packageName}/$assetKey';
      }
      return _Statement(
        type: 'String',
        filePath: assetType.posixStylePath,
        name: assetType.name,
        value: '\'$assetKey\'',
        isConstConstructor: false,
        isDirectory: false,
        needDartDoc: true,
      );
    } else {
      integration.isEnabled = true;
      return _Statement(
        type: integration.className,
        filePath: assetType.posixStylePath,
        name: assetType.name,
        value: integration.classInstantiate(assetType),
        isConstConstructor: integration.isConstConstructor,
        isDirectory: false,
        needDartDoc: true,
      );
    }
  }
  return null;
}

/// Generate style like Assets.foo.bar
Future<String> _dotDelimiterStyleDefinition(
  FileAssetsGenConfig config,
  List<Integration> integrations,
) async {
  final rootPath = Directory(config.input).absolute.uri.toFilePath();
  final packageName = generatePackageNameForConfig(config);
  final outputs = config.flutterGen.assets.outputs;
  final assetRelativePathList = _getAssetRelativePathList(
    rootPath,
    config.exclude,
  );
  final assetTypeQueue = ListQueue<AssetType>.from(
    _constructAssetTree(assetRelativePathList, rootPath).children,
  );

  final assetsStaticStatements = <_Statement>[];
  final buffer = StringBuffer();
  while (assetTypeQueue.isNotEmpty) {
    final assetType = assetTypeQueue.removeFirst();
    String assetPath = join(rootPath, assetType.path);
    final isDirectory = FileSystemEntity.isDirectorySync(assetPath);
    if (isDirectory) {
      assetPath = Directory(assetPath).absolute.uri.toFilePath();
    } else {
      assetPath = File(assetPath).absolute.uri.toFilePath();
    }

    final isRootAsset = !isDirectory &&
        File(assetPath).parent.absolute.uri.toFilePath() == rootPath;
    // Handles directories, and explicitly handles root path assets.
    if (isDirectory || isRootAsset) {
      final List<_Statement?> results = await Future.wait(
        assetType.children
            .mapToUniqueAssetType(camelCase, justBasename: true)
            .map((e) => _createAssetTypeStatement(config, e, integrations)),
      );
      final statements = results.whereType<_Statement>().toList();

      if (assetType.isDefaultAssetsDirectory) {
        assetsStaticStatements.addAll(statements);
      } else if (!isDirectory && isRootAsset) {
        // Creates explicit statement.
        final statement = await _createAssetTypeStatement(
          config,
          UniqueAssetType(assetType: assetType, style: camelCase),
          integrations,
        );
        assetsStaticStatements.add(statement!);
      } else {
        final className = '\$${assetType.path.camelCase().capitalize()}Gen';
        String? directoryPath;
        if (outputs.directoryPathEnabled) {
          directoryPath = assetType.posixStylePath;
          if (packageName != null) {
            directoryPath = 'packages/$packageName/$directoryPath';
          }
        }
        buffer.writeln(
          _directoryClassGenDefinition(className, statements, directoryPath),
        );
        // Add this directory reference to Assets class
        // if we are not under the default asset folder
        if (dirname(assetType.path) == '.') {
          assetsStaticStatements.add(
            _Statement(
              type: className,
              filePath: assetType.posixStylePath,
              name: assetType.baseName.camelCase(),
              value: '$className()',
              isConstConstructor: true,
              isDirectory: true,
              needDartDoc: true,
            ),
          );
        }
      }

      assetTypeQueue.addAll(assetType.children);
    }
  }
  buffer.writeln(
    _dotDelimiterStyleAssetsClassDefinition(
      outputs.className,
      assetsStaticStatements,
      packageName,
    ),
  );
  return buffer.toString();
}

typedef _StyleDefinition = Future<String> Function(
  FileAssetsGenConfig config,
  List<Integration> integrations,
);

/// Generate style like Assets.foo_bar
Future<String> _snakeCaseStyleDefinition(
  FileAssetsGenConfig config,
  List<Integration> integrations,
) {
  return _flatStyleDefinition(
    config,
    integrations,
    snakeCase,
  );
}

/// Generate style like Assets.fooBar
Future<String> _camelCaseStyleDefinition(
  FileAssetsGenConfig config,
  List<Integration> integrations,
) {
  return _flatStyleDefinition(
    config,
    integrations,
    camelCase,
  );
}

Future<String> _flatStyleDefinition(
  FileAssetsGenConfig config,
  List<Integration> integrations,
  String Function(String) style,
) async {
  final List<FlavoredAsset> paths = _getAssetRelativePathList(
    config.input,
    config.exclude,
  );
  paths.sort(((a, b) => a.path.compareTo(b.path)));
  final List<_Statement?> results = await Future.wait(
    paths
        .map(
          (assetPath) => AssetType(
            rootPath: config.input,
            path: assetPath.path,
            flavors: assetPath.flavors,
          ),
        )
        .mapToUniqueAssetType(style)
        .map(
          (e) => _createAssetTypeStatement(
            config,
            e,
            integrations,
          ),
        ),
  );
  final statements = results.whereType<_Statement>().toList();
  final className = config.flutterGen.assets.outputs.className;
  final String? packageName = generatePackageNameForConfig(config);
  return _flatStyleAssetsClassDefinition(className, statements, packageName);
}

String _flatStyleAssetsClassDefinition(
  String className,
  List<_Statement> statements,
  String? packageName,
) {
  final statementsBlock = statements
      .map(
        (statement) => '''${statement.toDartDocString()}
           ${statement.toStaticFieldString()}
           ''',
      )
      .join('\n');
  final valuesBlock = _assetValuesDefinition(statements, static: true);
  return _assetsClassDefinition(
    className,
    statements,
    statementsBlock,
    valuesBlock,
    packageName,
  );
}

String _dotDelimiterStyleAssetsClassDefinition(
  String className,
  List<_Statement> statements,
  String? packageName,
) {
  final statementsBlock =
      statements.map((statement) => statement.toStaticFieldString()).join('\n');
  final valuesBlock = _assetValuesDefinition(statements, static: true);
  return _assetsClassDefinition(
    className,
    statements,
    statementsBlock,
    valuesBlock,
    packageName,
  );
}

String _assetValuesDefinition(
  List<_Statement> statements, {
  bool static = false,
}) {
  final values = statements.where((element) => !element.isDirectory);
  if (values.isEmpty) {
    return '';
  }
  final names = values.map((value) => value.name).join(', ');
  final type = values.every((element) => element.type == values.first.type)
      ? values.first.type
      : 'dynamic';

  return '''
  /// List of all assets
  ${static ? 'static ' : ''}List<$type> get values => [$names];''';
}

String _assetsClassDefinition(
  String className,
  List<_Statement> statements,
  String statementsBlock,
  String valuesBlock,
  String? packageName,
) {
  return '''
class $className {
  const $className._();
${packageName != null ? "\n  static const String package = '$packageName';" : ''}

  $statementsBlock
  $valuesBlock
}
''';
}

String _directoryClassGenDefinition(
  String className,
  List<_Statement> statements,
  String? directoryPath,
) {
  final statementsBlock = statements.map((statement) {
    final buffer = StringBuffer();
    if (statement.needDartDoc) {
      buffer.writeln(statement.toDartDocString());
    }
    buffer.writeln(statement.toGetterString());
    return buffer.toString();
  }).join('\n');
  final pathBlock = directoryPath != null
      ? '''
  /// Directory path: $directoryPath
  String get path => '$directoryPath';
'''
      : '';
  final valuesBlock = _assetValuesDefinition(statements);

  return '''
class $className {
  const $className();
  
  $statementsBlock
  $pathBlock
  $valuesBlock
}
''';
}

/// The generated statement for each asset, e.g
/// '$type get $name => ${isConstConstructor ? 'const' : ''} $value;';
class _Statement {
  const _Statement({
    required this.type,
    required this.filePath,
    required this.name,
    required this.value,
    required this.isConstConstructor,
    required this.isDirectory,
    required this.needDartDoc,
  });

  /// The type of this asset, e.g AssetGenImage, SvgGenImage, String, etc.
  final String type;

  /// The relative path of this asset from the root directory.
  final String filePath;

  /// The variable name of this asset.
  final String name;

  /// The code to instantiate this asset. e.g `AssetGenImage('assets/image.png');`
  final String value;

  final bool isConstConstructor;
  final bool isDirectory;
  final bool needDartDoc;

  String toDartDocString() => '/// File path: $filePath';

  String toGetterString() {
    final buffer = StringBuffer('');
    if (isDirectory) {
      buffer.writeln(
        '/// Directory path: '
        '${Directory(filePath).path.replaceAll(r'\', r'/')}',
      );
    }
    buffer.writeln(
      '$type get $name => ${isConstConstructor ? 'const' : ''} $value;',
    );
    return buffer.toString();
  }

  String toStaticFieldString() => 'static const $type $name = $value;';
}
