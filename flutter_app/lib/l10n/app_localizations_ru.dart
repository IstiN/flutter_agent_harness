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
  String get appsChatEmptyHint =>
      'Пока пусто — спросите Fa об этом приложении.';

  @override
  String get appsCollapseChatTooltip => 'Свернуть чат';

  @override
  String get appsDismissReplyTooltip => 'Скрыть';

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
  String get appsOpenFullChatTooltip => 'Открыть полный чат';

  @override
  String get appsPermissionCalendar => 'Календарь';

  @override
  String get appsPermissionCalendarDesc =>
      'jsr.fa.calendar — чтение событий системного календаря';

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
  String get appsPermissionKeys => 'Ключи хоста';

  @override
  String get appsPermissionKeysDesc =>
      'jsr.fa.keys — доступ к API-ключам, сохранённым в Fa, и запрос новых';

  @override
  String get appsPermissionLlm => 'LLM';

  @override
  String get appsPermissionLlmDesc =>
      'jsr.fa.llm — разрешить приложению обращаться к подключённой модели';

  @override
  String get appsPermissionMedia => 'Медиа';

  @override
  String get appsPermissionMediaDesc =>
      'jsr.fa.media — генерация изображений, речи и музыки';

  @override
  String get appsPermissionMicrophone => 'Микрофон';

  @override
  String get appsPermissionMicrophoneDesc =>
      'jsr.fa.asr — запись аудио и распознавание речи';

  @override
  String get appsPermissionNetwork => 'Сеть';

  @override
  String get appsPermissionNetworkDesc =>
      'jsr.fetchJson — разрешить приложению вызывать HTTP API';

  @override
  String get appsPermissionNotifications => 'Уведомления';

  @override
  String get appsPermissionNotificationsDesc =>
      'jsr.fa.notify — локальные уведомления';

  @override
  String get appsPermissionsDone => 'Готово';

  @override
  String appsPermissionsTitle(Object name) {
    return 'Разрешения $name';
  }

  @override
  String get appsPermissionsTooltip => 'Разрешения приложения';

  @override
  String get appsCloseTooltip => 'Закрыть приложение';

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
  String get chatMicDenied =>
      'Доступ к микрофону запрещён. Разрешите его в системных настройках конфиденциальности (Конфиденциальность и безопасность → Микрофон) и попробуйте снова.';

  @override
  String chatMicError(Object error) {
    return 'Ошибка голосового ввода: $error';
  }

  @override
  String get chatMicStopTooltip => 'Остановить запись';

  @override
  String get chatMicTooltip => 'Голосовой ввод';

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
  String get chatTyping => 'Fa печатает...';

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
  String get filePreviewEdit => 'Изменить';

  @override
  String get filePreviewSave => 'Сохранить';

  @override
  String get filePreviewSaved => 'Сохранено';

  @override
  String get filePreviewSaveError => 'Ошибка сохранения';

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
  String filesFolderPickerError(Object error) {
    return 'Не удалось открыть выбор папки: $error';
  }

  @override
  String filesICloudSyncDone(Object files, Object size, Object when) {
    return 'Синхронизировано файлов: $files ($size) — последняя синхронизация $when';
  }

  @override
  String filesICloudSyncFailed(Object error) {
    return 'Ошибка синхронизации iCloud: $error';
  }

  @override
  String get filesICloudSyncTooltip =>
      'Синхронизировать сессии и приложения с iCloud';

  @override
  String get filesICloudSyncUnavailable =>
      'Синхронизация iCloud недоступна — включите iCloud Drive для Fa в Настройки → Apple ID → iCloud';

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
  String get keysAddButton => 'Добавить ключ';

  @override
  String get keysAddDialogTitle => 'Добавить ключ';

  @override
  String get keysAddNameDuplicate => 'Ключ с таким именем уже существует.';

  @override
  String get keysAddNameHint => 'GITHUB_TOKEN';

  @override
  String get keysAddNameInvalid =>
      'Используйте A–Z, 0–9 и подчёркивания, начиная с буквы.';

  @override
  String get keysAddNameLabel => 'Имя';

  @override
  String get keysDeleteBody =>
      'Сохранённое значение удаляется с этого устройства. Значение из файла .env, если оно есть, снова вступит в силу.';

  @override
  String keysDeleteTitle(Object name) {
    return 'Удалить $name?';
  }

  @override
  String get keysSectionNote =>
      'Значения никогда не показываются. Сохранённые ключи хранятся на этом устройстве; сессионные исчезают после перезагрузки.';

  @override
  String get keysSectionTitle => 'Ключи';

  @override
  String get keysSetButton => 'Задать';

  @override
  String keysSetDialogTitle(Object name) {
    return 'Задать $name';
  }

  @override
  String get keysSourceEnv => 'файл .env';

  @override
  String get keysSourceNone => 'не задан';

  @override
  String get keysSourceProviderSession => 'ключ провайдера · эта сессия';

  @override
  String get keysSourceSaved => 'сохранён';

  @override
  String get keysValueHint => 'Вставьте значение ключа';

  @override
  String get keysValueLabel => 'Значение';

  @override
  String get launcherChatActionsTooltip => 'Действия чата';

  @override
  String get launcherChatEmptyHint => 'Пока пусто — спросите Fa о чём угодно.';

  @override
  String get launcherDissolveFolder => 'Убрать папку';

  @override
  String get launcherFolderDefaultName => 'Папка';

  @override
  String get launcherFolderNameHint => 'Название папки';

  @override
  String launcherOpenAppError(Object error) {
    return 'Не удалось открыть приложение: $error';
  }

  @override
  String get launcherRenameFolderTooltip => 'Переименовать папку';

  @override
  String get launcherRestoreDemoApp => 'Восстановить эталонную версию';

  @override
  String get launcherRestoreDemoAppDone =>
      'Код приложения восстановлен (данные сохранены)';

  @override
  String get launcherRestoreDemoAppFailed =>
      'Не удалось восстановить приложение';

  @override
  String get launcherSeedErrorCopy => 'Скопировать ошибку';

  @override
  String get launcherSeedErrorHint =>
      'Отправьте эту ошибку Fa — он сможет починить приложение.';

  @override
  String get launcherSeedErrorTitle => 'Приложение не установилось';

  @override
  String get launcherTileSizeLarge => 'Большой (4×4)';

  @override
  String get launcherTileSizeMedium => 'Средний (4×2)';

  @override
  String get launcherTileSizeReset => 'По умолчанию';

  @override
  String get launcherTileSizeSmall => 'Маленький (2×2)';

  @override
  String get mediaFileMissing => 'Медиафайл не найден';

  @override
  String get mediaModelsApiKeyNameHelper =>
      'Имя сохранённого ключа (см. «Ключи») — никогда сам ключ. Пусто — ключ основного подключения.';

  @override
  String get mediaModelsApiKeyNameLabel => 'Имя ключа API (необязательно)';

  @override
  String get mediaModelsCapabilitiesNote =>
      'Модели этого эндпоинта поддерживают:';

  @override
  String get mediaModelsClearButton => 'Сбросить';

  @override
  String mediaModelsEditTitle(Object slot) {
    return 'Изменить: $slot';
  }

  @override
  String get mediaModelsFallbackSummary => 'Как основное подключение';

  @override
  String get mediaModelsMainConnection => 'Основное подключение';

  @override
  String mediaModelsOverrideSummary(Object host, Object modelId) {
    return '$modelId · $host';
  }

  @override
  String get mediaModelsSectionNote =>
      'Запросы изображений, аудио, видео и транскрипции используют основное подключение, если слот не переопределён.';

  @override
  String get mediaModelsSectionTitle => 'Медиамодели';

  @override
  String get mediaModelsSlotAudioTts => 'Синтез речи';

  @override
  String get mediaModelsSlotImageGeneration => 'Генерация изображений';

  @override
  String get mediaModelsSlotMusicGeneration => 'Генерация музыки';

  @override
  String get mediaModelsSlotTranscription => 'Транскрипция';

  @override
  String get mediaModelsSlotVideoGeneration => 'Генерация видео';

  @override
  String get mediaModelsSlotVision => 'Зрение (чтение изображений)';

  @override
  String get mediaMuteTooltip => 'Выключить звук';

  @override
  String get mediaPauseTooltip => 'Пауза';

  @override
  String get mediaPlayTooltip => 'Воспроизвести';

  @override
  String get mediaUnmuteTooltip => 'Включить звук';

  @override
  String get mediaVideoUnsupportedWeb =>
      'Воспроизведение видео не поддерживается в веб-сборке';

  @override
  String get modelPresetBudgetDescription =>
      'Самый дешёвый надёжный набор на каждый день — быстрый чат и все медиа через OpenRouter';

  @override
  String get modelPresetBudgetName => 'Оптимальный по цене';

  @override
  String get modelPresetQualityDescription =>
      'Топовый чат и флагманская генерация изображений — самый сильный набор на OpenRouter';

  @override
  String get modelPresetQualityName => 'Качество';

  @override
  String get modelPresetsApplied => 'Применено';

  @override
  String get modelPresetsChatLabel => 'Чат';

  @override
  String modelPresetsKeyMissing(Object provider) {
    return 'Для этого пресета нужен ключ API $provider.';
  }

  @override
  String get modelPresetsSectionTitle => 'Пресеты моделей';

  @override
  String get modelPresetsSetKey => 'Задать ключ';

  @override
  String get onboardingAiDisclaimer =>
      'Ответы дают сторонние ИИ-провайдеры, которых вы подключаете. ИИ может ошибаться и быть неполным — всегда проверяйте важную информацию.';

  @override
  String get onboardingAiDisclaimerTitle => 'ИИ может ошибаться';

  @override
  String get onboardingFeatureApps =>
      'Создаёт настоящие мини-приложения с живыми виджетами прямо на домашнем экране';

  @override
  String get onboardingFeatureAutomation =>
      'Автоматизирует календарь, напоминания и умный дом';

  @override
  String get onboardingFeatureMedia =>
      'Генерирует изображения, музыку и видео по запросу';

  @override
  String get onboardingGetStarted => 'Начать';

  @override
  String get onboardingModelsBody =>
      'Один тап применяет целый набор — чат плюс модели для изображений, музыки и видео. Всё можно изменить позже в настройках.';

  @override
  String get onboardingModelsSetUpLater => 'Настроить позже';

  @override
  String get onboardingModelsTitle => 'Выберите модели';

  @override
  String get onboardingNext => 'Далее';

  @override
  String get onboardingPermissionCalendar => 'Календарь';

  @override
  String get onboardingPermissionCalendarDesc => 'Планирование событий';

  @override
  String get onboardingPermissionContacts => 'Контакты';

  @override
  String get onboardingPermissionContactsDesc => 'Звонки и сообщения';

  @override
  String get onboardingPermissionHealth => 'Здоровье';

  @override
  String get onboardingPermissionHealthDesc => 'Сводки активности';

  @override
  String get onboardingPermissionHome => 'Дом';

  @override
  String get onboardingPermissionHomeDesc => 'Управление умным домом';

  @override
  String get onboardingPermissionMicrophone => 'Микрофон';

  @override
  String get onboardingPermissionMicrophoneDesc => 'Голосовой ввод';

  @override
  String get onboardingPermissionNotifications => 'Уведомления';

  @override
  String get onboardingPermissionNotificationsDesc =>
      'Напоминания и оповещения';

  @override
  String get onboardingPermissionsBody =>
      'Всё это необязательно — основной чат работает и без этого. Fa спрашивает разрешение только в контексте, когда функции оно действительно нужно, а изменить решение можно в любой момент в системных настройках.';

  @override
  String get onboardingPermissionsTitle => 'Разрешения — на ваших условиях';

  @override
  String get onboardingPrivacyKeysDesc =>
      'Ключи API хранятся в системной связке ключей (iOS/macOS) или локальном защищённом хранилище — никогда в журналах чата.';

  @override
  String get onboardingPrivacyKeysTitle => 'Ключи под замком';

  @override
  String get onboardingPrivacyOnDeviceDesc =>
      'Ваши переписки и файлы остаются на этом устройстве.';

  @override
  String get onboardingPrivacyOnDeviceTitle =>
      'Чаты и файлы остаются на устройстве';

  @override
  String get onboardingPrivacyPolicyLink => 'Политика конфиденциальности';

  @override
  String get onboardingPrivacyProvidersDesc =>
      'Контент отправляется только тем ИИ-провайдерам, которых вы явно подключили.';

  @override
  String get onboardingPrivacyProvidersTitle => 'Провайдеров выбираете вы';

  @override
  String get onboardingPrivacyTitle => 'Ваши данные остаются вашими';

  @override
  String get onboardingSkip => 'Пропустить';

  @override
  String get onboardingWelcomeBody =>
      'Общайтесь с ИИ-агентом, который делает реальную работу, а не просто разговаривает.';

  @override
  String get onboardingWelcomeTitle => 'Знакомьтесь, Fa';

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
  String get secretRequestInvalidName =>
      'Только UPPER_SNAKE: A–Z, 0–9, _, начиная с буквы';

  @override
  String get secretRequestNameLabel => 'Имя ключа';

  @override
  String get secretRequestNotNow => 'Не сейчас';

  @override
  String get secretRequestSave => 'Сохранить';

  @override
  String get secretRequestTitle => 'Fa нужен ключ';

  @override
  String get secretRequestValueLabel => 'Значение ключа';

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
  String get settingsCopyDebugLogs => 'Скопировать логи отладки';

  @override
  String get settingsSendTestCrashReport => 'Отправить тестовый краш-репорт';

  @override
  String get settingsTestCrashReportNoFirebase =>
      'Crashlytics не инициализирован на этом устройстве';

  @override
  String get settingsTestCrashReportSent =>
      'Тестовый репорт отправлен — проверьте консоль Firebase через пару минут';

  @override
  String get settingsDebugLogsCopied =>
      'Логи отладки скопированы в буфер обмена';

  @override
  String get settingsCorsNoteOllama =>
      'Запросы идут напрямую из браузера на ollama.com, который сейчас не отправляет заголовки CORS, — вызовы из браузера завершаются ошибкой. Используйте здесь OpenRouter или выберите Ollama в мобильном/десктопном приложении.';

  @override
  String get settingsDefaultChatModelTitle => 'Модель чата по умолчанию';

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
  String get settingsEditorKeyNoteSecure =>
      'Имя, URL и модель сохраняются; ключ хранится в Keychain на этом устройстве.';

  @override
  String get settingsEditorKeepKeyNote =>
      'Для этого провайдера сохранён ключ — оставьте поле пустым, чтобы не менять его.';

  @override
  String get settingsHfTokenHint => 'hf_… — нужен, если репозиторий закрытый';

  @override
  String get settingsHfTokenLabel => 'Токен HuggingFace (необязательно)';

  @override
  String get settingsKeyNoteCustom =>
      'Определение провайдера (имя, URL, модель) сохраняется — без секретов. Ключ API хранится в памяти только в течение этого сеанса и исчезает после перезагрузки.';

  @override
  String get settingsKeyNoteCustomSecure =>
      'Определение провайдера (имя, URL, модель) сохраняется — без секретов. Сохранённые ключи хранятся в Keychain на этом устройстве; несохранённый ключ остаётся в памяти только на этот сеанс.';

  @override
  String get settingsKeyNoteHosted =>
      'Только в памяти: ваш ключ нигде не сохраняется и исчезает после перезагрузки. Запросы идут напрямую из браузера к провайдеру — ничего не проксируется и не хранится.';

  @override
  String get settingsKeyNoteHostedSecure =>
      'Сохранённые ключи хранятся в Keychain на этом устройстве; ключ, только введённый в форму, остаётся в памяти на этот сеанс. Запросы идут напрямую из приложения к провайдеру — ничего не проксируется.';

  @override
  String get settingsLoadingModel => 'Загрузка модели…';

  @override
  String get settingsModelIdLabel => 'ID модели';

  @override
  String get settingsModelIdOptionalLabel => 'ID модели (необязательно)';

  @override
  String get settingsModelIdRequired => 'Требуется ID модели';

  @override
  String get settingsModelsFetching => 'Загрузка списка моделей с эндпоинта…';

  @override
  String get settingsModelsGroupTitle => 'Модели';

  @override
  String get settingsNameRequired => 'Требуется имя';

  @override
  String get settingsOnDeviceModelLabel => 'Модель на устройстве';

  @override
  String get settingsPickModelTitle => 'Выбор модели';

  @override
  String get settingsPickProviderTitle => 'Выбор провайдера';

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
  String settingsProviderModelSummary(Object model, Object provider) {
    return '$model · $provider';
  }

  @override
  String get settingsProviderNameHint => 'Мой провайдер';

  @override
  String get settingsProviderNameLabel => 'Имя';

  @override
  String get settingsProvidersSectionTitle => 'Провайдеры';

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
  String get settingsSkillsAccess => 'Доступ к навыкам';

  @override
  String get settingsSkillsAccessHint =>
      'Использовать навыки Claude, Copilot или Codex из папки проекта (.claude, .github, .codex)';

  @override
  String get skillsAccessAsk => 'Спрашивать';

  @override
  String get skillsAccessAllowed => 'Разрешено';

  @override
  String get skillsAccessDenied => 'Запрещено';

  @override
  String get skillsAccessDialogTitle =>
      'Использовать существующие навыки агентов?';

  @override
  String get skillsAccessDialogBody =>
      'В проекте могут быть навыки Claude, Copilot или Codex (папки .claude, .github, .codex) — инструкции, оставленные другими инструментами на этом устройстве. Fa может использовать их в ваших задачах.';

  @override
  String get skillsAccessAllow => 'Разрешить';

  @override
  String get skillsAccessNotNow => 'Не сейчас';

  @override
  String get settingsThemeDark => 'Тёмная';

  @override
  String get settingsThemeLabel => 'Тема';

  @override
  String get settingsThemeLight => 'Светлая';

  @override
  String get settingsThemeSystem => 'Как в системе';

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
  String get taskModelSameAsMain => 'Как основная';

  @override
  String get taskModelSave => 'Сохранить';

  @override
  String get taskModelSectionTitle => 'Модели для задач';

  @override
  String get taskModelSmolDescription => 'Для саммари и сабагентов';

  @override
  String get taskModelSmolTitle => 'Быстрая модель';

  @override
  String get taskModelUseMain => 'Использовать основную';

  @override
  String get setupAppBarTitle => 'Подключение к Fa';

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
  String get sidebarRenameClear => 'Сбросить';

  @override
  String get sidebarRenameDialogTitle => 'Переименовать сессию';

  @override
  String get sidebarRenameHint => 'Пустое имя вернёт название по умолчанию.';

  @override
  String get sidebarRenameNameLabel => 'Название';

  @override
  String get sidebarRenameSessionTooltip => 'Переименовать сессию';

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

  @override
  String get settingsIconsPerRow => 'Иконок в ряд';

  @override
  String get settingsIconsPerRowHint =>
      'Колонок в сетке домашнего экрана; Авто — 4 на телефоне, 6 на широких';

  @override
  String get settingsIconsPerRowAuto => 'Авто';

  @override
  String get settingsShowOnboarding => 'Показать приветствие';

  @override
  String get chatSteerTooltip => 'Отправить сейчас (прервать)';

  @override
  String bootstrapSessionStartError(Object error) {
    return 'Не удалось запустить сессию: $error';
  }

  @override
  String get bootstrapRetry => 'Повторить';

  @override
  String get workspaceDialogTitle => 'Рабочая папка';

  @override
  String get workspaceDialogChangeFolder => 'Сменить папку…';

  @override
  String get workspaceDialogClearFolder => 'Использовать личную папку';

  @override
  String get workspaceDialogClose => 'Закрыть';

  @override
  String get workspaceDialogCurrentFolder => 'Текущая папка';

  @override
  String get workspaceDialogHostPath => 'Путь на хосте';

  @override
  String get workspaceDialogMountHint =>
      'Файлы по /project/... в агенте указывают на эту папку на вашем Mac.';

  @override
  String get workspaceDialogUnsupported =>
      'Проектные папки сейчас доступны только на macOS.';

  @override
  String get workspaceDialogPersonal => 'Личная (папка не выбрана)';

  @override
  String get workspaceDialogMailbox => 'Ваш mailbox';

  @override
  String get workspaceDialogMailboxHint =>
      'Другие инстансы Fa могут писать этой сессии на этот адрес.';

  @override
  String get workspaceDialogMailboxCopy => 'Копировать';

  @override
  String get workspaceDialogMailboxCopied => 'Адрес mailbox скопирован';

  @override
  String get workspaceDialogRestrictTools =>
      'Ограничить инструменты этой папкой';

  @override
  String get workspaceDialogRestrictToolsHint =>
      'Отключает всё, что читало или писало бы за пределами смонтированной папки. Попытки выйти за рамки будут блокироваться (и в будущем — просить вашего подтверждения через диалог).';
}
