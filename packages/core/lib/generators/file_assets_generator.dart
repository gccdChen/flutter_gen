import 'dart:collection';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dartx/dartx.dart' hide IterableSorted;
import 'package:flutter_gen_core/generators/generator_helper.dart';
import 'package:flutter_gen_core/generators/integrations/file_image_integration.dart';
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
      FileImageIntegration(
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
  String rootPath,
  List<Glob> excludes,
  bool firstDirAsFlavor, // 新增参数
) {
  final assetRelativePathList = <FlavoredAsset>[];

  if (firstDirAsFlavor) {
    // 如果启用 firstDirAsFlavor，扫描逻辑有所不同
    final rootDir = Directory(rootPath);
    final flavorDirs = rootDir.listSync().whereType<Directory>();
    
    // 收集所有 flavor 目录名
    final flavorNames = flavorDirs.map((dir) => basename(dir.path)).toSet();

    // 按 flavor 目录分别处理资源文件
    for (final flavorDir in flavorDirs) {
      final flavorName = basename(flavorDir.path);
      _scanFlavorDirectory(flavorDir, rootPath, flavorName, assetRelativePathList);
    }

    // 重新处理路径，移除 flavor 前缀
    final processedAssets = <FlavoredAsset>[];
    for (final asset in assetRelativePathList) {
      final parts = asset.path.split('/');
      if (parts.isNotEmpty && flavorNames.contains(parts.first)) {
        final newPath = parts.skip(1).join('/');
        // 合并相同路径但不同 flavor 的资产
        final existingAsset = processedAssets.firstOrNullWhere((a) => a.path == newPath);
        if (existingAsset != null) {
          existingAsset.flavors.addAll(asset.flavors);
        } else {
          processedAssets.add(FlavoredAsset(path: newPath, flavors: asset.flavors));
        }
      }
    }
    assetRelativePathList.clear();
    assetRelativePathList.addAll(processedAssets);
  } else {
    // 原有的扫描逻辑
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

    final rootDir = Directory(rootPath);
    final children = rootDir.listSync();
    for (final child in children) {
      if (child is Directory) {
        final flavor = basename(child.path);
        traverseDirectory(child, flavor);
      }
    }
  }

  if (excludes.isEmpty) {
    return assetRelativePathList;
  }
  return assetRelativePathList
      .where((asset) => !excludes.any((exclude) => exclude.matches(asset.path)))
      .toList();
}


// 用于扫描 flavor 目录的辅助函数
void _scanFlavorDirectory(
  Directory flavorDir,
  String rootPath,
  String flavorName,
  List<FlavoredAsset> assetList,
) {
  void scanRecursively(Directory dir, String relativePath) {
    final entities = dir.listSync();
    for (final entity in entities) {
      if (entity is Directory) {
        final dirRelativePath = '$relativePath/${basename(entity.path)}';
        scanRecursively(entity, dirRelativePath);
      } else if (entity is File) {
        final fileRelativePath = '$relativePath/${basename(entity.path)}';
        final asset = FlavoredAsset(path: fileRelativePath, flavors: {flavorName});
        assetList.add(asset);
      }
    }
  }
  
  // 从 flavor 目录开始扫描，保留 flavor 名称作为路径的一部分
  scanRecursively(flavorDir, flavorName);
}




AssetType _constructAssetTree(
  List<FlavoredAsset> assetRelativePathList,
  String rootPath,
  bool firstDirAsFlavor, // 新增参数
) {
  // 根资产类型
  final root = AssetType(rootPath: rootPath, path: '.', flavors: {});
  
  if (firstDirAsFlavor) {
    // 对于 firstDirAsFlavor 模式，我们需要构建一个不同的树结构
    // 首先按路径的第一段分组（这将成为 Assets 类中的静态字段）
    final topLevelDirs = <String, Set<String>>{};
    
    for (final asset in assetRelativePathList) {
      final parts = asset.path.split('/');
      if (parts.length > 0) {
        final topDir = parts[0];
        topLevelDirs.putIfAbsent(topDir, () => {}).addAll(asset.flavors);
      }
    }
    
    // 为每个顶级目录创建一个 AssetType
    for (final entry in topLevelDirs.entries) {
      final topDirName = entry.key;
      final flavors = entry.value;
      final topDirType = AssetType(
        rootPath: rootPath,
        path: topDirName,
        flavors: flavors,
      );
      root.addChild(topDirType);
      
      // 为该顶级目录下的所有资产创建其余树结构
      final assetsInDir = assetRelativePathList
          .where((asset) => asset.path.startsWith('$topDirName/') || asset.path == topDirName)
          .toList();
      
      for (final asset in assetsInDir) {
        String path = asset.path;
        final parts = path.split('/');
        
        AssetType currentParent = topDirType;
        String currentPath = topDirName;
        
        // 从第二段开始构建子树
        for (int i = 1; i < parts.length; i++) {
          currentPath = '$currentPath/${parts[i]}';
          final childType = currentParent.children.firstOrNullWhere(
            (child) => child.path == currentPath,
          );
          
          if (childType != null) {
            childType.flavors.addAll(asset.flavors);
            currentParent = childType;
          } else {
            final newChild = AssetType(
              rootPath: rootPath,
              path: currentPath,
              flavors: Set.from(asset.flavors),
            );
            currentParent.addChild(newChild);
            currentParent = newChild;
          }
        }
      }
    }
  } else {
    // 原有的树构建逻辑
    final assetTypeMap = <String, AssetType>{
      '.': root,
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
    
    // 构造 AssetType 树
    for (final assetType in assetTypeMap.values) {
      if (assetType.path == '.') {
        continue;
      }
      final parentPath = dirname(assetType.path);
      assetTypeMap[parentPath]?.addChild(assetType);
    }
  }
  
  return root;
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
    
    // 构建 flavors 参数（如果有）
    String flavorsParam = '';
    if (assetType.flavors.isNotEmpty) {
      final flavorsStr = assetType.flavors
          .map((f) => "'$f'")
          .join(', ');
      flavorsParam = ', flavors: {$flavorsStr}';
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
      
      // 为 integration.classInstantiate 方法添加 flavors 支持
      String instantiateValue = integration.classInstantiate(assetType);
      
      // 如果是启用了 firstDirAsFlavor 并且有 flavors，将其添加到实例化代码中
      if (config.flutterGen.file?.firstDirAsFlavor == true && assetType.flavors.isNotEmpty) {
        // 假设所有集成类的实例化格式类似于 "ClassName('path/to/asset')"
        // 我们需要在结尾括号前添加 flavors 参数
        if (instantiateValue.endsWith(')')) {
          instantiateValue = instantiateValue.substring(0, instantiateValue.length - 1) + flavorsParam + ')';
        }
      }
      
      return _Statement(
        type: integration.className,
        filePath: assetType.posixStylePath,
        name: assetType.name,
        value: instantiateValue,
        isConstConstructor: integration.isConstConstructor,
        isDirectory: false,
        needDartDoc: true,
      );
    }
  }
  return null;
}


Future<String> _dotDelimiterStyleDefinition(
  FileAssetsGenConfig config,
  List<Integration> integrations,
) async {
  final rootPath = Directory(config.input).absolute.uri.toFilePath();
  final packageName = generatePackageNameForConfig(config);
  final outputs = config.flutterGen.assets.outputs;
  final firstDirAsFlavor = config.flutterGen.file?.firstDirAsFlavor ?? false;
  
  final assetRelativePathList = _getAssetRelativePathList(
    rootPath,
    config.exclude,
    firstDirAsFlavor,
  );
  
  final rootAssetType = _constructAssetTree(
    assetRelativePathList,
    rootPath,
    firstDirAsFlavor,
  );
  
  final ListQueue<AssetType> assetTypeQueue = ListQueue<AssetType>.from(
    rootAssetType.children,
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
    
    final isRoot = File(assetPath).parent.absolute.uri.toFilePath() == rootPath;
    final isRootAsset = !isDirectory && isRoot;
    
    // 处理目录或根路径资产
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
        // 创建明确的语句
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
        
        // 如果我们使用 firstDirAsFlavor 模式，并且这是顶级目录
        // 将此目录引用添加到 Assets 类
        if (firstDirAsFlavor || dirname(assetType.path) == '.') {
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
  final firstDirAsFlavor = config.flutterGen.file?.firstDirAsFlavor ?? false;
  
  final List<FlavoredAsset> paths = _getAssetRelativePathList(
    config.input,
    config.exclude,
    firstDirAsFlavor,
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
