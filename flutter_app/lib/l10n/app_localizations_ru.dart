// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Fa';

  @override
  String get approvalAllowOnce => 'Разрешить один раз';

  @override
  String approvalAllowToolTitle(Object tool) {
    return 'Разрешить $tool?';
  }

  @override
  String get approvalAlwaysAllow => 'Всегда разрешать';

  @override
  String get approvalDeny => 'Запретить';

  @override
  String get approvalModeAlwaysAsk => 'Всегда спрашивать';

  @override
  String get approvalModeAlwaysAskHint =>
      'Каждый вызов инструмента требует разрешения.';

  @override
  String get approvalModeTitle => 'Разрешения инструментов';

  @override
  String get approvalModeWrite => 'Запись';

  @override
  String get approvalModeWriteHint =>
      'Чтение файлов выполняется свободно; запись, правки и команды оболочки требуют разрешения.';

  @override
  String get approvalModeYolo => 'YOLO';

  @override
  String get approvalModeYoloHint =>
      'Все инструменты запускаются без запроса (разрушительные команды оболочки всё равно спрашивают).';

  @override
  String approvalTierLabel(Object tier) {
    return 'Уровень: $tier';
  }

  @override
  String appsAskFaAbout(Object name) {
    return 'Спросить Fa о $name';
  }

  @override
  String get appsAskFaHint => 'например: сделай кнопки больше и фиолетовыми';

  @override
  String get appsAskFaSubtitle =>
      'Fa получит ваше сообщение, состояние приложения и скриншот.';

  @override
  String get appsAskFaTooltip => 'Спросить Fa об этом приложении';

  @override
  String get appsEmptyState =>
      'Пока нет приложений. Попросите Fa создать одно —\nоно появится в папке apps/.';

  @override
  String get appsFaStatusThinking => 'думает…';

  @override
  String get appsFaStatusWorking => 'Fa работает…';

  @override
  String get appsFaStatusWriting => 'пишет…';

  @override
  String get appsFollowUpHint => 'Уточнить…';

  @override
  String get appsGridTitle => 'Приложения';

  @override
  String appsLoadError(Object error) {
    return 'Не удалось загрузить приложения: $error';
  }

  @override
  String get appsOpenChatTooltip => 'Открыть чат';

  @override
  String get appsPermissionContacts => 'Контакты';

  @override
  String get appsPermissionContactsDesc =>
      'jsr.fa.contacts — адресная книга (скоро)';

  @override
  String get appsPermissionHealth => 'Здоровье';

  @override
  String get appsPermissionHealthDesc =>
      'jsr.fa.health — данные о здоровье (скоро)';

  @override
  String get appsPermissionHomekit => 'HomeKit';

  @override
  String get appsPermissionHomekitDesc =>
      'jsr.fa.homekit — устройства умного дома (скоро)';

  @override
  String get appsPermissionLlm => 'LLM';

  @override
  String get appsPermissionLlmDesc =>
      'jsr.fa.llm — разрешить приложению обращаться к подключённой модели';

  @override
  String get appsPermissionNetwork => 'Сеть';

  @override
  String get appsPermissionNetworkDesc =>
      'jsr.fetchJson — разрешить приложению вызывать HTTP API';

  @override
  String get appsPermissionsDone => 'Готово';

  @override
  String appsPermissionsTitle(Object name) {
    return 'Разрешения $name';
  }

  @override
  String get appsPermissionsTooltip => 'Разрешения приложения';

  @override
  String get appsRefreshTooltip => 'Обновить';

  @override
  String get appsReloadTooltip => 'Перезагрузить приложение';

  @override
  String get appsSendToFa => 'Отправить Fa';

  @override
  String get appsSendTooltip => 'Отправить';

  @override
  String appsStartError(Object error, Object name) {
    return 'Не удалось запустить $name:\n$error';
  }

  @override
  String get appsStopTooltip => 'Остановить';

  @override
  String get askAnswerAction => 'Ответить';

  @override
  String get askBack => 'Назад';

  @override
  String get askCancel => 'Отмена';

  @override
  String get askNext => 'Далее';

  @override
  String get askOtherLabel => 'Другое (введите свой вариант)';

  @override
  String askQuestionProgress(Object index, Object total) {
    return 'Вопрос $index из $total';
  }

  @override
  String get askQuestionTitle => 'Вопрос';

  @override
  String get askRecommended => 'Рекомендуется';

  @override
  String get askYourAnswerLabel => 'Ваш ответ';

  @override
  String get cacheBrowserSubtitle =>
      'Веса on-device моделей хранятся в кэше браузера. Удаление освобождает место; модель скачается снова при следующем использовании.';

  @override
  String cacheDeleteTitle(Object name) {
    return 'Удалить $name?';
  }

  @override
  String cacheDeleteTooltip(Object name) {
    return 'Удалить $name';
  }

  @override
  String cacheDeleteWeightsBrowser(Object size) {
    return 'Удаляет скачанные веса ($size) из кэша браузера. Модель скачается снова при следующем использовании.';
  }

  @override
  String cacheEntryCached(Object bytes, Object size) {
    return '$size · в кэше $bytes';
  }

  @override
  String get cacheNoModels => 'Модели ещё не загружены.';

  @override
  String cacheNoticeDeleteFailed(Object error, Object name) {
    return 'Не удалось удалить $name: $error';
  }

  @override
  String cacheNoticeDeleted(Object name) {
    return '$name удалена.';
  }

  @override
  String cacheNoticeLoadedModel(Object name) {
    return '$name была загружена — она скачается снова при следующем использовании.';
  }

  @override
  String get chatAbortTooltip => 'Прервать';

  @override
  String chatAttachError(Object error, Object name) {
    return 'Не удалось прикрепить $name: $error';
  }

  @override
  String get chatAttachFile => 'Прикрепить файл';

  @override
  String chatAttachNoName(Object name) {
    return 'Не удалось прикрепить «$name»: нет подходящего имени файла.';
  }

  @override
  String get chatAttachTooltip => 'Прикрепить';

  @override
  String get chatCamera => 'Камера';

  @override
  String get chatCollapse => 'Свернуть';

  @override
  String get chatCopiedToClipboard => 'Сессия скопирована в буфер обмена';

  @override
  String get chatCopySessionTooltip => 'Копировать сессию';

  @override
  String get chatFilesTooltip => 'Файлы';

  @override
  String get chatGallery => 'Галерея';

  @override
  String get chatInputHint => 'Введите сообщение';

  @override
  String get chatRemoveAttachment => 'Удалить вложение';

  @override
  String chatSendError(Object error) {
    return 'Не удалось отправить: $error';
  }

  @override
  String get chatSendTooltip => 'Отправить';

  @override
  String get chatSessionsTooltip => 'Сессии и модель';

  @override
  String get chatSettingsTooltip => 'Настройки подключения';

  @override
  String chatShowAll(Object count) {
    return 'Показать все ($count)';
  }

  @override
  String get chatTyping => 'fah печатает...';

  @override
  String chatUploadFailed(Object error) {
    return 'Ошибка загрузки: $error';
  }

  @override
  String get commonCancel => 'Отмена';

  @override
  String get commonDelete => 'Удалить';

  @override
  String get filePreviewCannotRead => 'Не удалось прочитать файл';

  @override
  String get filePreviewCannotStat => 'Не удалось получить сведения о файле';

  @override
  String get filePreviewDecodeError => 'Не удалось декодировать изображение';

  @override
  String get filePreviewLoadError => 'Не удалось загрузить файл';

  @override
  String get filePreviewNoPreview => 'Предпросмотр недоступен';

  @override
  String get filePreviewTabPreview => 'Просмотр';

  @override
  String get filePreviewTabSource => 'Исходный код';

  @override
  String get filePreviewTooLarge => 'Файл слишком большой для предпросмотра';

  @override
  String filePreviewTruncated(Object size) {
    return 'Показаны первые $size — вывод обрезан';
  }

  @override
  String get filesBackTooltip => 'Назад к файлам';

  @override
  String get filesEmptyFileName => '(пустое имя файла)';

  @override
  String get filesEmptyFolder => 'Пустая папка';

  @override
  String get filesFolderAccessDenied =>
      'Не удалось получить доступ к этой папке.';

  @override
  String get filesListFolderError => 'Не удалось прочитать содержимое папки';

  @override
  String filesMountUnavailableTooltip(Object path) {
    return 'Ранее использованная папка недоступна: $path — нажмите, чтобы выбрать снова';
  }

  @override
  String get filesOpenFolderError => 'Не удалось открыть папку';

  @override
  String get filesOpenProjectFolderTooltip => 'Открыть папку проекта…';

  @override
  String get filesPanelTitle => 'Файлы';

  @override
  String get filesRefreshTooltip => 'Обновить';

  @override
  String get filesRetryButton => 'Повторить';

  @override
  String filesUnmountTooltip(Object path) {
    return 'Отключить $path';
  }

  @override
  String get filesUpTooltip => 'Вверх';

  @override
  String filesUploadFailed(Object error) {
    return 'Ошибка загрузки: $error';
  }

  @override
  String filesUploadFailures(Object count, Object names) {
    return ', не удалось ($count): $names';
  }

  @override
  String filesUploadSummary(Object failures, num uploaded) {
    String _temp0 = intl.Intl.pluralLogic(
      uploaded,
      locale: localeName,
      other: 'Загружено $uploaded файла',
      many: 'Загружено $uploaded файлов',
      few: 'Загружено $uploaded файла',
      one: 'Загружен $uploaded файл',
    );
    return '$_temp0$failures';
  }

  @override
  String get filesUploadTooltip => 'Загрузить файлы сюда';

  @override
  String gemmaCacheDeleteOrphan(Object size, Object storage) {
    return 'Удаляет файл ($size) из $storage. Установленные модели не затрагиваются.';
  }

  @override
  String gemmaCacheDeleteWeights(Object size, Object storage) {
    return 'Удаляет скачанные веса ($size) из $storage. Модель скачается снова при следующем использовании.';
  }

  @override
  String get gemmaCacheMobileOnly =>
      'On-device модели (Gemma) доступны только в iOS/Android сборках (в вебе on-device Gemma покрывает провайдер transformers.js).';

  @override
  String gemmaCacheScanError(Object error) {
    return 'Не удалось просканировать кэш моделей: $error';
  }

  @override
  String gemmaCacheSubtitle(Object storage) {
    return 'Веса Gemma хранятся $storage. Удаление освобождает место; модель скачается снова при следующем использовании.';
  }

  @override
  String get gemmaCacheTitle => 'Модели на устройстве (Gemma)';

  @override
  String get gemmaStorageFromBrowser => 'хранилища браузера';

  @override
  String get gemmaStorageFromDevice => 'устройства';

  @override
  String get gemmaStorageInBrowser => 'в вашем браузере';

  @override
  String get gemmaStorageOnDevice => 'на этом устройстве';

  @override
  String quickStartCachedLabel(Object bytes, Object size) {
    return '$size · $bytes в кеше';
  }

  @override
  String get quickStartLoading => 'Загрузка модели…';

  @override
  String get quickStartSubtitle =>
      'Уже на этом устройстве — один тап, ключ API не нужен.';

  @override
  String get quickStartTitle => 'Загруженные модели';

  @override
  String get quickStartUse => 'Использовать';

  @override
  String get settingsAddProvider => 'Добавить провайдера';

  @override
  String get settingsApiKeyHint => 'Вставьте ключ провайдера';

  @override
  String get settingsApiKeyLabel => 'Ключ API';

  @override
  String get settingsApiKeyLocalHelper =>
      'Оставьте пустым для локальных серверов (llama.cpp, Ollama, LM Studio)';

  @override
  String get settingsApiKeyOptionalLabel => 'Ключ API (необязательно)';

  @override
  String get settingsApiKeyRequired => 'Требуется ключ API';

  @override
  String get settingsApplyButton => 'Применить';

  @override
  String get settingsBaseUrlHelper => 'OpenAI-совместимая конечная точка';

  @override
  String get settingsBaseUrlLabel => 'Базовый URL';

  @override
  String get settingsBaseUrlRequired => 'Требуется базовый URL';

  @override
  String get settingsCancelButton => 'Отмена';

  @override
  String get settingsCoderBadge => 'для кода';

  @override
  String get settingsCorsNoteCustom =>
      'Любая OpenAI-совместимая конечная точка. Провайдер должен разрешать браузерные (CORS) запросы — api.anthropic.com их не разрешает, поэтому к моделям Anthropic обращайтесь через OpenRouter.';

  @override
  String get settingsCorsNoteOllama =>
      'Запросы идут напрямую из браузера на ollama.com, который сейчас не отправляет заголовки CORS, — вызовы из браузера завершаются ошибкой. Используйте здесь OpenRouter или выберите Ollama в мобильном/десктопном приложении.';

  @override
  String get settingsDeleteButton => 'Удалить';

  @override
  String get settingsDeleteProviderBody =>
      'Провайдер удаляется из списка выбора. Текущее подключение не затрагивается.';

  @override
  String settingsDeleteProviderTitle(Object name) {
    return 'Удалить $name?';
  }

  @override
  String get settingsDownloadingWeights => 'Скачивание весов модели…';

  @override
  String get settingsEditButton => 'Изменить';

  @override
  String get settingsEditProviderTitle => 'Изменить провайдера';

  @override
  String get settingsEditorKeyNote =>
      'Имя, URL и модель сохраняются; ключ хранится в памяти только для этого сеанса — он не записывается на диск.';

  @override
  String get settingsHfTokenHint => 'hf_… — нужен, если репозиторий закрытый';

  @override
  String get settingsHfTokenLabel => 'Токен HuggingFace (необязательно)';

  @override
  String get settingsKeyNoteCustom =>
      'Определение провайдера (имя, URL, модель) сохраняется — без секретов. Ключ API хранится в памяти только в течение этого сеанса и исчезает после перезагрузки.';

  @override
  String get settingsKeyNoteHosted =>
      'Только в памяти: ваш ключ нигде не сохраняется и исчезает после перезагрузки. Запросы идут напрямую из браузера к провайдеру — ничего не проксируется и не хранится.';

  @override
  String get settingsLoadingModel => 'Загрузка модели…';

  @override
  String get settingsModelIdLabel => 'ID модели';

  @override
  String get settingsModelIdRequired => 'Требуется ID модели';

  @override
  String get settingsNameRequired => 'Требуется имя';

  @override
  String get settingsOnDeviceModelLabel => 'Модель на устройстве';

  @override
  String get settingsPresetCustom => 'Пользовательский';

  @override
  String get settingsPresetGemma => 'На устройстве (Gemma)';

  @override
  String get settingsPresetOllama => 'Ollama';

  @override
  String get settingsPresetOpenrouter => 'OpenRouter';

  @override
  String get settingsPresetTransformersJs =>
      'На устройстве (Gemma, transformers.js)';

  @override
  String get settingsPresetWebllm => 'На устройстве (WebLLM)';

  @override
  String get settingsProviderLabel => 'Провайдер';

  @override
  String get settingsProviderNameHint => 'Мой провайдер';

  @override
  String get settingsProviderNameLabel => 'Имя';

  @override
  String get settingsSaveButton => 'Сохранить';

  @override
  String settingsStaleModelCache(Object model) {
    return 'Ранее использованная модель ($model) удалена из кеша — выберите модель, чтобы скачать её снова.';
  }

  @override
  String settingsStaleModelDevice(Object model) {
    return 'Ранее использованная модель ($model) удалена с этого устройства — выберите модель, чтобы скачать её снова.';
  }

  @override
  String get settingsStartChat => 'Начать чат';

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get settingsToolsBadge => 'инструменты через промпт';

  @override
  String get settingsTransformersJsNote =>
      'Работает полностью офлайн после скачивания · требуется WebGPU (Chrome/Edge/новые Safari) · весы скачиваются один раз с HuggingFace (публичный репозиторий, токен не нужен) и кешируются в браузере';

  @override
  String get settingsVisionBadge => 'зрение';

  @override
  String get settingsWebllmNote =>
      'Работает полностью офлайн после скачивания · требуется WebGPU (Chrome/Edge/новые Safari) · веса ~0.5-4 ГБ кешируются в браузере';

  @override
  String get setupAppBarTitle => 'Подключение к fah';

  @override
  String sidebarAllApps(Object count) {
    return 'Все приложения ($count)';
  }

  @override
  String get sidebarAppsHeader => 'Приложения';

  @override
  String get sidebarCancel => 'Отмена';

  @override
  String get sidebarDelete => 'Удалить';

  @override
  String sidebarDeletePersistedContent(Object id) {
    return 'Сессия $id';
  }

  @override
  String get sidebarDeleteSessionContent =>
      'Сохранённая сессия будет удалена безвозвратно.';

  @override
  String sidebarDeleteSessionFailed(Object error) {
    return 'Не удалось удалить сессию: $error';
  }

  @override
  String get sidebarDeleteSessionTitle => 'Удалить сессию?';

  @override
  String get sidebarDeleteSessionTooltip => 'Удалить сессию';

  @override
  String get sidebarLoadSessionsError => 'Не удалось загрузить сессии';

  @override
  String get sidebarModelHeader => 'Модель';

  @override
  String get sidebarNewSessionTooltip => 'Новая сессия';

  @override
  String get sidebarNoActiveSession => 'Нет активной сессии';

  @override
  String get sidebarNoModel => 'нет модели';

  @override
  String get sidebarNoSessions => 'Пока нет сессий';

  @override
  String get sidebarOnThisDevice => 'На этом устройстве';

  @override
  String get sidebarOpenAppsGridTooltip => 'Открыть все приложения';

  @override
  String get sidebarProviderAnthropic => 'Anthropic';

  @override
  String get sidebarProviderGoogle => 'Google';

  @override
  String get sidebarProviderOnDeviceWebllm => 'На устройстве (WebLLM)';

  @override
  String get sidebarProviderOpenaiCompatible => 'OpenAI-совместимый API';

  @override
  String get sidebarRefreshAppsTooltip => 'Обновить приложения';

  @override
  String get sidebarRefreshSessionsTooltip => 'Обновить сессии';

  @override
  String get sidebarRetry => 'Повторить';

  @override
  String sidebarSessionTitle(Object id) {
    return 'сессия $id';
  }

  @override
  String get sidebarSessionsHeader => 'Сессии';

  @override
  String get tjsCacheTitle => 'Загруженные модели (transformers.js)';

  @override
  String get tjsCacheWebOnly =>
      'On-device модели (transformers.js) доступны только в веб-сборке.';

  @override
  String uploadTooLarge(Object max, Object total) {
    return 'Загрузка слишком большая: $total превышает лимит $max на один пакет.';
  }

  @override
  String get webllmCacheManagedByOs =>
      'На этой платформе on-device модели управляются хранилищем ОС/приложения.';

  @override
  String get webllmCacheTitle => 'Загруженные модели';

  @override
  String get settingsVisionLabel => 'Поддерживает изображения (vision)';
}
