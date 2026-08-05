import 'dart:io';

import 'utils/dotenv_loader.dart';

Map<String, String> get systemEnvironment => Platform.environment;

Map<String, String> loadDotEnvValues([String path = '.env']) => loadDotEnv(path);
