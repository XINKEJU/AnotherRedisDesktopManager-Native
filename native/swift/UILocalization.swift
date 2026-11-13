import Foundation

// MARK: - Multilingual UI layer (all 13 upstream languages)

/// Exact label -> upstream message key. Those keys already have hand-written
/// translations in all 13 language files, so no duplicated dictionary is needed.
let uiAliases: [String: String] = [
    "Add row": "add_new_line",
    "Appearance": "ui_settings",
    "Auto refresh": "auto_refresh",
    "Clean": "clean_up",
    "Close": "close",
    "Close Connection": "close_connection",
    "Close Other Tabs": "close_other",
    "Close Tabs to the Right": "close_right",
    "Collapse all": "collapse_all",
    "Connections": "config_connections",
    "Copy": "copy",
    "Dark": "theme_dark",
    "Delete Connection": "del_connection",
    "Duplicate Connection": "duplicate_connection",
    "Edit": "edit",
    "Edit Connection": "edit_connection",
    "Expand all": "expand_all",
    "Font family": "font_family",
    "General": "common_settings",
    "Group": "group",
    "Group name": "group_name",
    "Host": "host",
    "Key name": "key_name",
    "Light": "theme_light",
    "Memory": "memory",
    "Memory Analysis": "memory_analysis",
    "New Connection": "new_connection",
    "New Group": "new_group",
    "New Group…": "new_group",
    "New Key": "add_new_key",
    "Open": "open",
    "Password": "password",
    "Port": "port",
    "Redis CLI": "redis_console",
    "Refresh": "refresh_connection",
    "Refresh Keys": "refresh_connection",
    "Save": "save",
    "Server": "server",
    "Settings": "settings",
    "Settings…": "settings",
    "Test Connection": "test_connection",
]

/// Column order for the compact phrase / word tables below.
let uiTableLanguages = ["de", "es", "fr", "it", "ko", "pt", "ru", "tr", "tw", "ua", "vi"]

/// High-frequency complete labels, translated per language (English | 11 translations).
let uiPhraseRows: [String] = [
    "Save|Speichern|Guardar|Enregistrer|Salva|저장|Salvar|Сохранить|Kaydet|儲存|Зберегти|Lưu",
    "Cancel|Abbrechen|Cancelar|Annuler|Annulla|취소|Cancelar|Отмена|İptal|取消|Скасувати|Hủy",
    "Delete|Löschen|Eliminar|Supprimer|Elimina|삭제|Excluir|Удалить|Sil|刪除|Видалити|Xóa",
    "Refresh|Aktualisieren|Actualizar|Actualiser|Aggiorna|새로 고침|Atualizar|Обновить|Yenile|重新整理|Оновити|Làm mới",
    "Settings|Einstellungen|Configuración|Paramètres|Impostazioni|설정|Configurações|Настройки|Ayarlar|設定|Налаштування|Cài đặt",
    "Connect|Verbinden|Conectar|Connecter|Connetti|연결|Conectar|Подключиться|Bağlan|連線|Підключитися|Kết nối",
    "Disconnect|Trennen|Desconectar|Déconnecter|Disconnetti|연결 해제|Desconectar|Отключиться|Bağlantıyı kes|中斷連線|Відключитися|Ngắt kết nối",
    "New Connection|Neue Verbindung|Nueva conexión|Nouvelle connexion|Nuova connessione|새 연결|Nova conexão|Новое подключение|Yeni bağlantı|新增連線|Нове підключення|Kết nối mới",
    "New Key|Neuer Schlüssel|Nueva clave|Nouvelle clé|Nuova chiave|새 키|Nova chave|Новый ключ|Yeni anahtar|新增鍵|Новий ключ|Khóa mới",
    "Keys|Schlüssel|Claves|Clés|Chiavi|키|Chaves|Ключі|Anahtarlar|鍵|Ключі|Khóa",
    "Key|Schlüssel|Clave|Clé|Chiave|키|Chave|Ключ|Anahtar|鍵|Ключ|Khóa",
    "Value|Wert|Valor|Valeur|Valore|값|Valor|Значение|Değer|值|Значення|Giá trị",
    "Search keys|Schlüssel suchen|Buscar claves|Rechercher des clés|Cerca chiavi|키 검색|Pesquisar chaves|Поиск ключей|Anahtar ara|搜尋鍵|Пошук ключів|Tìm khóa",
    "Not connected|Nicht verbunden|No conectado|Non connecté|Non connesso|연결되지 않음|Não conectado|Не подключено|Bağlı değil|未連線|Не підключено|Chưa kết nối",
    "Disconnected|Getrennt|Desconectado|Déconnecté|Disconnesso|연결 끊김|Desconectado|Отключено|Bağlantı kesildi|已中斷|Відключено|Đã ngắt kết nối",
    "Select a key to view and edit its value|Wählen Sie einen Schlüssel zum Anzeigen und Bearbeiten|Seleccione una clave para ver y editar su valor|Sélectionnez une clé pour afficher et modifier sa valeur|Seleziona una chiave per visualizzarne e modificarne il valore|값을 보고 편집할 키를 선택하세요|Selecione uma chave para ver e editar seu valor|Выберите ключ для просмотра и изменения|Görüntülemek ve düzenlemek için bir anahtar seçin|選擇一個鍵以檢視與編輯其值|Виберіть ключ для перегляду та редагування|Chọn một khóa để xem và sửa giá trị",
    "Language|Sprache|Idioma|Langue|Lingua|언어|Idioma|Язык|Dil|語言|Мова|Ngôn ngữ",
    "Theme|Design|Tema|Thème|Tema|테마|Tema|Тема|Tema|主題|Тема|Chủ đề",
    "Font family|Schriftfamilie|Familia de fuentes|Famille de police|Famiglia di caratteri|글꼴 계열|Família da fonte|Семейство шрифтов|Yazı tipi ailesi|字型家族|Сімейство шрифтів|Họ phông chữ",
    "Zoom|Zoom|Zoom|Zoom|Zoom|확대/축소|Zoom|Масштаб|Yakınlaştırma|縮放|Масштаб|Thu phóng",
    "Database|Datenbank|Base de datos|Base de données|Database|데이터베이스|Banco de dados|База данных|Veritabanı|資料庫|База даних|Cơ sở dữ liệu",
    "Read-only|Schreibgeschützt|Solo lectura|Lecture seule|Sola lettura|읽기 전용|Somente leitura|Только для чтения|Salt okunur|唯讀|Лише читання|Chỉ đọc",
    "Favorites|Favoriten|Favoritos|Favoris|Preferiti|즐겨찾기|Favoritos|Избранное|Favoriler|收藏|Обране|Yêu thích",
    "Connections|Verbindungen|Conexiones|Connexions|Connessioni|연결|Conexões|Подключения|Bağlantılar|連線|Підключення|Kết nối",
    "Viewer|Ansicht|Visor|Visionneuse|Visualizzatore|뷰어|Visualizador|Просмотр|Görüntüleyici|檢視器|Перегляд|Trình xem",
    "Status|Status|Estado|État|Stato|상태|Estado|Состояние|Durum|狀態|Стан|Trạng thái",
    "Slow Log|Langsames Protokoll|Registro lento|Journal lent|Log lenti|느린 로그|Log lento|Медленный лог|Yavaş günlük|慢日誌|Повільний журнал|Nhật ký chậm",
    "Memory|Speicher|Memoria|Mémoire|Memoria|메모리|Memória|Память|Bellek|記憶體|Пам'ять|Bộ nhớ",
    "Cluster|Cluster|Clúster|Cluster|Cluster|클러스터|Cluster|Кластер|Küme|叢集|Кластер|Cụm",
    "Monitor|Überwachung|Monitor|Surveiller|Monitor|모니터|Monitor|Монитор|İzleme|監控|Монітор|Giám sát",
    "Command Log|Befehlsprotokoll|Registro de comandos|Journal des commandes|Log comandi|명령 로그|Log de comandos|Журнал команд|Komut günlüğü|命令日誌|Журнал команд|Nhật ký lệnh",
    "Check for Updates|Nach Updates suchen|Buscar actualizaciones|Rechercher des mises à jour|Cerca aggiornamenti|업데이트 확인|Verificar atualizações|Проверить обновления|Güncellemeleri kontrol et|檢查更新|Перевірити оновлення|Kiểm tra cập nhật",
    "Error|Fehler|Error|Erreur|Errore|오류|Erro|Ошибка|Hata|錯誤|Помилка|Lỗi",
    "OK|OK|Aceptar|OK|OK|확인|OK|ОК|Tamam|確定|Гаразд|OK",
]

/// Single-word lexicon used as a fallback for labels without an exact entry.
let uiLexiconRows: [String] = [
    "New|Neu|Nuevo|Nouveau|Nuovo|새|Novo|Новый|Yeni|新增|Новий|Mới",
    "Connection|Verbindung|Conexión|Connexion|Connessione|연결|Conexão|Подключение|Bağlantı|連線|Підключення|Kết nối",
    "Key|Schlüssel|Clave|Clé|Chiave|키|Chave|Ключ|Anahtar|鍵|Ключ|Khóa",
    "Value|Wert|Valor|Valeur|Valore|값|Valor|Значение|Değer|值|Значення|Giá trị",
    "Type|Typ|Tipo|Type|Tipo|유형|Tipo|Тип|Tür|類型|Тип|Loại",
    "Name|Name|Nombre|Nom|Nome|이름|Nome|Имя|Ad|名稱|Назва|Tên",
    "Host|Host|Host|Hôte|Host|호스트|Host|Хост|Sunucu|主機|Хост|Máy chủ",
    "Port|Port|Puerto|Port|Porta|포트|Porta|Порт|Port|連接埠|Порт|Cổng",
    "Password|Passwort|Contraseña|Mot de passe|Password|비밀번호|Senha|Пароль|Parola|密碼|Пароль|Mật khẩu",
    "Search|Suchen|Buscar|Rechercher|Cerca|검색|Pesquisar|Поиск|Ara|搜尋|Пошук|Tìm",
    "Copy|Kopieren|Copiar|Copier|Copia|복사|Copiar|Копировать|Kopyala|複製|Копіювати|Sao chép",
    "Open|Öffnen|Abrir|Ouvrir|Apri|열기|Abrir|Открыть|Aç|開啟|Відкрити|Mở",
    "Close|Schließen|Cerrar|Fermer|Chiudi|닫기|Fechar|Закрыть|Kapat|關閉|Закрити|Đóng",
    "Edit|Bearbeiten|Editar|Modifier|Modifica|편집|Editar|Изменить|Düzenle|編輯|Редагувати|Sửa",
    "Add|Hinzufügen|Añadir|Ajouter|Aggiungi|추가|Adicionar|Добавить|Ekle|新增|Додати|Thêm",
    "Remove|Entfernen|Quitar|Retirer|Rimuovi|제거|Remover|Удалить|Kaldır|移除|Видалити|Xóa",
    "Delete|Löschen|Eliminar|Supprimer|Elimina|삭제|Excluir|Удалить|Sil|刪除|Видалити|Xóa",
    "Start|Start|Iniciar|Démarrer|Avvia|시작|Iniciar|Запустить|Başlat|開始|Запустити|Bắt đầu",
    "Stop|Stop|Detener|Arrêter|Ferma|중지|Parar|Остановить|Durdur|停止|Зупинити|Dừng",
    "Run|Ausführen|Ejecutar|Exécuter|Esegui|실행|Executar|Выполнить|Çalıştır|執行|Виконати|Chạy",
    "Clear|Leeren|Limpiar|Effacer|Pulisci|지우기|Limpar|Очистить|Temizle|清除|Очистити|Xóa",
    "Filter|Filtern|Filtrar|Filtrer|Filtra|필터|Filtrar|Фильтр|Filtre|篩選|Фільтр|Lọc",
    "Language|Sprache|Idioma|Langue|Lingua|언어|Idioma|Язык|Dil|語言|Мова|Ngôn ngữ",
    "Theme|Design|Tema|Thème|Tema|테마|Tema|Тема|Tema|主題|Тема|Chủ đề",
    "Font|Schrift|Fuente|Police|Carattere|글꼴|Fonte|Шрифт|Yazı tipi|字型|Шрифт|Phông chữ",
    "Zoom|Zoom|Zoom|Zoom|Zoom|확대|Zoom|Масштаб|Yakınlaştırma|縮放|Масштаб|Thu phóng",
    "Tools|Werkzeuge|Herramientas|Outils|Strumenti|도구|Ferramentas|Инструменты|Araçlar|工具|Інструменти|Công cụ",
    "View|Ansicht|Ver|Vue|Vista|보기|Ver|Вид|Görünüm|檢視|Вигляд|Xem",
    "Status|Status|Estado|État|Stato|상태|Estado|Состояние|Durum|狀態|Стан|Trạng thái",
    "Memory|Speicher|Memoria|Mémoire|Memoria|메모리|Memória|Память|Bellek|記憶體|Пам'ять|Bộ nhớ",
    "Cluster|Cluster|Clúster|Cluster|Cluster|클러스터|Cluster|Кластер|Küme|叢集|Кластер|Cụm",
    "Monitor|Überwachung|Monitor|Surveiller|Monitor|모니터|Monitor|Монитор|İzleme|監控|Монітор|Giám sát",
    "Import|Importieren|Importar|Importer|Importa|가져오기|Importar|Импорт|İçe aktar|匯入|Імпорт|Nhập",
    "Export|Exportieren|Exportar|Exporter|Esporta|내보내기|Exportar|Экспорт|Dışa aktar|匯出|Експорт|Xuất",
    "Group|Gruppe|Grupo|Groupe|Gruppo|그룹|Grupo|Группа|Grup|分組|Група|Nhóm",
    "Create|Erstellen|Crear|Créer|Crea|만들기|Criar|Создать|Oluştur|建立|Створити|Tạo",
    "Load|Laden|Cargar|Charger|Carica|불러오기|Carregar|Загрузить|Yükle|載入|Завантажити|Tải",
    "Limit|Limit|Límite|Limite|Limite|제한|Limite|Лимит|Sınır|限制|Ліміт|Giới hạn",
    "Database|Datenbank|Base de datos|Base de données|Database|데이터베이스|Banco de dados|База данных|Veritabanı|資料庫|База даних|Cơ sở dữ liệu",
    "Server|Server|Servidor|Serveur|Server|서버|Servidor|Сервер|Sunucu|伺服器|Сервер|Máy chủ",
    "Previous|Zurück|Anterior|Précédent|Precedente|이전|Anterior|Назад|Önceki|上一頁|Назад|Trước",
    "Next|Weiter|Siguiente|Suivant|Successivo|다음|Próximo|Далее|Sonraki|下一頁|Далі|Tiếp",
    "Confirm|Bestätigen|Confirmar|Confirmer|Conferma|확인|Confirmar|Подтвердить|Onayla|確認|Підтвердити|Xác nhận",
    "Help|Hilfe|Ayuda|Aide|Aiuto|도움말|Ajuda|Справка|Yardım|說明|Довідка|Trợ giúp",
    "About|Über|Acerca de|À propos|Informazioni|정보|Sobre|О программе|Hakkında|關於|Про програму|Giới thiệu",
    "Update|Update|Actualización|Mise à jour|Aggiornamento|업데이트|Atualização|Обновление|Güncelleme|更新|Оновлення|Cập nhật",
    "Version|Version|Versión|Version|Versione|버전|Versão|Версия|Sürüm|版本|Версія|Phiên bản",
    "Field|Feld|Campo|Champ|Campo|필드|Campo|Поле|Alan|欄位|Поле|Trường",
    "Member|Element|Miembro|Membre|Membro|멤버|Membro|Элемент|Üye|成員|Елемент|Phần tử",
    "Index|Index|Índice|Index|Indice|인덱스|Índice|Индекс|İndeks|索引|Індекс|Chỉ số",
    "Score|Score|Puntuación|Score|Punteggio|점수|Pontuação|Счёт|Puan|分數|Рахунок|Điểm",
    "Binary|Binär|Binario|Binaire|Binario|바이너리|Binário|Двоичный|İkili|二進位|Двійковий|Nhị phân",
    "Custom|Benutzerdefiniert|Personalizado|Personnalisé|Personalizzato|사용자 정의|Personalizado|Пользовательский|Özel|自訂|Користувацький|Tùy chỉnh",
    "Favorites|Favoriten|Favoritos|Favoris|Preferiti|즐겨찾기|Favoritos|Избранное|Favoriler|收藏|Обране|Yêu thích",
    "Command|Befehl|Comando|Commande|Comando|명령|Comando|Команда|Komut|命令|Команда|Lệnh",
    "Log|Protokoll|Registro|Journal|Log|로그|Log|Журнал|Günlük|日誌|Журнал|Nhật ký",
    "Message|Nachricht|Mensaje|Message|Messaggio|메시지|Mensagem|Сообщение|Mesaj|訊息|Повідомлення|Thông điệp",
    "Channel|Kanal|Canal|Canal|Canale|채널|Canal|Канал|Kanal|頻道|Канал|Kênh",
    "Pattern|Muster|Patrón|Motif|Modello|패턴|Padrão|Шаблон|Desen|模式|Шаблон|Mẫu",
    "Subscribe|Abonnieren|Suscribirse|S'abonner|Iscriviti|구독|Inscrever-se|Подписаться|Abone ol|訂閱|Підписатися|Đăng ký",
    "Publish|Veröffentlichen|Publicar|Publier|Pubblica|발행|Publicar|Опубликовать|Yayınla|發布|Опублікувати|Xuất bản",
    "Selected|Ausgewählt|Seleccionado|Sélectionné|Selezionato|선택됨|Selecionado|Выбрано|Seçili|已選取|Вибрано|Đã chọn",
    "All|Alle|Todos|Tous|Tutti|전체|Todos|Все|Tümü|全部|Усі|Tất cả",
    "Auto|Automatisch|Automático|Automatique|Automatico|자동|Automático|Авто|Otomatik|自動|Авто|Tự động",
    "Page|Seite|Página|Page|Pagina|페이지|Página|Страница|Sayfa|頁|Сторінка|Trang",
    "Row|Zeile|Fila|Ligne|Riga|행|Linha|Строка|Satır|列|Рядок|Hàng",
    "Seconds|Sekunden|Segundos|Secondes|Secondi|초|Segundos|Секунды|Saniye|秒|Секунди|Giây",
    "Size|Größe|Tamaño|Taille|Dimensione|크기|Tamanho|Размер|Boyut|大小|Розмір|Kích thước",
    "Info|Info|Información|Informations|Informazioni|정보|Informações|Информация|Bilgi|資訊|Інформація|Thông tin",
    "Nodes|Knoten|Nodos|Nœuds|Nodi|노드|Nós|Узлы|Düğümler|節點|Вузли|Nút",
    "Slots|Slots|Ranuras|Slots|Slot|슬롯|Slots|Слоты|Yuvalar|槽位|Слоти|Khe",
    "Topology|Topologie|Topología|Topologie|Topologia|토폴로지|Topologia|Топология|Topoloji|拓撲|Топологія|Topologi",
    "Groups|Gruppen|Grupos|Groupes|Gruppi|그룹|Grupos|Группы|Gruplar|群組|Групи|Nhóm",
    "Consumers|Verbraucher|Consumidores|Consommateurs|Consumer|컨슈머|Consumidores|Потребители|Tüketiciler|消費者|Споживачі|Người tiêu dùng",
    "Timestamp|Zeitstempel|Marca de tiempo|Horodatage|Timestamp|타임스탬프|Timestamp|Метка времени|Zaman damgası|時間戳|Мітка часу|Dấu thời gian",
    "Sample|Stichprobe|Muestra|Échantillon|Campione|샘플|Amostra|Образец|Örnek|樣本|Зразок|Mẫu",
    "Path|Pfad|Ruta|Chemin|Percorso|경로|Caminho|Путь|Yol|路徑|Шлях|Đường dẫn",
    "Offset|Offset|Desplazamiento|Décalage|Offset|오프셋|Deslocamento|Смещение|Ofset|位移|Зсув|Độ lệch",
    "Editor|Editor|Editor|Éditeur|Editor|편집기|Editor|Редактор|Düzenleyici|編輯器|Редактор|Trình soạn thảo",
    "Format|Format|Formato|Format|Formato|형식|Formato|Формат|Biçim|格式|Формат|Định dạng",
    "Formatter|Formatierer|Formateador|Formateur|Formattatore|포매터|Formatador|Форматтер|Biçimlendirici|格式器|Форматувальник|Bộ định dạng",
    "Settings|Einstellungen|Configuración|Paramètres|Impostazioni|설정|Configurações|Настройки|Ayarlar|設定|Налаштування|Cài đặt",
    "Save|Speichern|Guardar|Enregistrer|Salva|저장|Salvar|Сохранить|Kaydet|儲存|Зберегти|Lưu",
    "Refresh|Aktualisieren|Actualizar|Actualiser|Aggiorna|새로 고침|Atualizar|Обновить|Yenile|重新整理|Оновити|Làm mới",
    "Connect|Verbinden|Conectar|Connecter|Connetti|연결|Conectar|Подключиться|Bağlan|連線|Підключитися|Kết nối",
    "Disconnect|Trennen|Desconectar|Déconnecter|Disconnetti|연결 해제|Desconectar|Отключиться|Bağlantıyı kes|中斷連線|Відключитися|Ngắt kết nối",
]

// MARK: - Lookup

private let uiPhraseIndex: [String: [String: String]] = {
    var out: [String: [String: String]] = [:]
    for row in uiPhraseRows {
        let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == uiTableLanguages.count + 1 else { continue }
        var map: [String: String] = [:]
        for (i, lang) in uiTableLanguages.enumerated() { map[lang] = parts[i + 1] }
        out[parts[0]] = map
    }
    return out
}()

private let uiLexicon: [String: [String: String]] = {
    var out: [String: [String: String]] = [:]
    for row in uiLexiconRows {
        let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == uiTableLanguages.count + 1 else { continue }
        var map: [String: String] = [:]
        for (i, lang) in uiTableLanguages.enumerated() { map[lang] = parts[i + 1] }
        out[parts[0].lowercased()] = map
    }
    return out
}()

/// Word-wise fallback: keeps punctuation and capitalisation, translates known words.
func uiWordwise(_ english: String, _ lang: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]*")
    let ns = english as NSString
    let matches = pattern.matches(in: english, range: NSRange(location: 0, length: ns.length))
    var result = NSString(string: english)
    for m in matches.reversed() {
        let word = ns.substring(with: m.range)
        guard let entry = uiLexicon[word.lowercased()], let translated = entry[lang],
              !translated.isEmpty else { continue }
        let replacement = word.first?.isUppercase == true ? translated.capitalized : translated
        result = result.replacingCharacters(in: m.range, with: replacement) as NSString
    }
    let out = result as String
    return out == english ? ARDMLocalization.shared().tText(english) : out
}

/// Resolve a UI label in the active language, with a strict priority order.
func uiLocalized(_ english: String) -> String {
    let loc = ARDMLocalization.shared()
    let lang = loc.currentLanguage
    if lang == "cn", let zh = uiChinese[english] { return zh }
    if lang == "en" { return english }
    // Traditional Chinese has its own upstream table for aliased keys.
    if let key = uiAliases[english] {
        let full = "message." + key
        let value = loc.t(full)
        if value != full && !value.isEmpty { return value }
    }
    if let phrase = uiPhraseIndex[english]?[lang], !phrase.isEmpty { return phrase }
    return uiWordwise(english, lang)
}
