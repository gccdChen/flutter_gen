
pubspec.yaml 配置
```
flutter_gen:
  file:
    enabled: true
    inputs:
      - sdcard/assets/
    first_dir_as_flavor: true 
    
```


期望生成 lib/gen/file_assets.gen.dart 文件

生成逻辑跟 assets_gen.dart 类似