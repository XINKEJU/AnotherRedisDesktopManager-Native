#import "ARDM.h"

#pragma mark - Small UI helpers

static NSTextField *ARDMLabel(NSString *text, NSRect frame) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.stringValue = text; f.editable = NO; f.bezeled = NO; f.drawsBackground = NO;
    f.font = [NSFont systemFontOfSize:12];
    return f;
}

static NSTextField *ARDMInput(NSString *value, NSRect frame, NSInteger tag) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.stringValue = value ?: @""; f.tag = tag; f.font = [NSFont systemFontOfSize:12];
    return f;
}

static NSButton *ARDMSwitch(NSString *title, NSRect frame, BOOL on, NSInteger tag) {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    b.buttonType = NSButtonTypeSwitch; b.title = title; b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.tag = tag; b.font = [NSFont systemFontOfSize:12];
    return b;
}

static NSScrollView *ARDMTable(NSRect frame, NSString *columnTitle) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    scroll.hasVerticalScroller = YES; scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.title = columnTitle; col.width = frame.size.width - 20;
    [table addTableColumn:col];
    table.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 24)];
    table.rowHeight = 22;
    table.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = table;
    return scroll;
}

#pragma mark - Application delegate

@interface ARDMAppDelegate ()
@property (nonatomic, strong) ARDMMainWindowController *windowController;
@end

@implementation ARDMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildMainMenu];
    self.windowController = [[ARDMMainWindowController alloc] init];
    [self.windowController showWindow:nil];
    [app activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)buildMainMenu {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About ARDM Native" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self.windowController; [appMenu addItem:settings];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit ARDM Native" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu]; [main addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"Connection"];
    NSMenuItem *newConn = [[NSMenuItem alloc] initWithTitle:@"New Connection" action:@selector(addConnection:) keyEquivalent:@"n"];
    newConn.target = self.windowController; [fileMenu addItem:newConn];
    NSMenuItem *connect = [[NSMenuItem alloc] initWithTitle:@"Connect" action:@selector(connectSelected:) keyEquivalent:@"\r"];
    connect.target = self.windowController; [fileMenu addItem:connect];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"Import Connections…" action:@selector(importConnections:) keyEquivalent:@"i"];
    importItem.target = self.windowController; [fileMenu addItem:importItem];
    NSMenuItem *exportItem = [[NSMenuItem alloc] initWithTitle:@"Export Connections…" action:@selector(exportConnections:) keyEquivalent:@"e"];
    exportItem.target = self.windowController; [fileMenu addItem:exportItem];
    [fileItem setSubmenu:fileMenu]; [main addItem:fileItem];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Keys" action:@selector(reloadKeys:) keyEquivalent:@"r"];
    refresh.target = self.windowController; [viewMenu addItem:refresh];
    NSMenuItem *cli = [[NSMenuItem alloc] initWithTitle:@"Redis CLI" action:@selector(showCli:) keyEquivalent:@"t"];
    cli.target = self.windowController; [viewMenu addItem:cli];
    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:@"Server Status" action:@selector(showStatus:) keyEquivalent:@""];
    status.target = self.windowController; [viewMenu addItem:status];
    NSMenuItem *slow = [[NSMenuItem alloc] initWithTitle:@"Slow Log" action:@selector(showSlowLog:) keyEquivalent:@""];
    slow.target = self.windowController; [viewMenu addItem:slow];
    NSMenuItem *memory = [[NSMenuItem alloc] initWithTitle:@"Memory Analysis" action:@selector(showMemoryAnalysis:) keyEquivalent:@""];
    memory.target = self.windowController; [viewMenu addItem:memory];
    NSMenuItem *cmdlog = [[NSMenuItem alloc] initWithTitle:@"Command Log" action:@selector(showCommandLog:) keyEquivalent:@""];
    cmdlog.target = self.windowController; [viewMenu addItem:cmdlog];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *theme = [[NSMenuItem alloc] initWithTitle:@"Toggle Dark Mode" action:@selector(toggleTheme:) keyEquivalent:@"d"];
    theme.target = self.windowController; [viewMenu addItem:theme];
    [viewItem setSubmenu:viewMenu]; [main addItem:viewItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu]; [main addItem:editItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(miniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(zoom:) keyEquivalent:@""];
    [windowItem setSubmenu:windowMenu]; [main addItem:windowItem];
    [NSApp setWindowsMenu:windowMenu];

    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *hotkeys = [[NSMenuItem alloc] initWithTitle:@"Keyboard Shortcuts" action:@selector(showHotkeys:) keyEquivalent:@""];
    hotkeys.target = self.windowController; [helpMenu addItem:hotkeys];
    [helpItem setSubmenu:helpMenu]; [main addItem:helpItem];
    [NSApp setMainMenu:main];
}

- (void)showSettings:(id)sender { [self.windowController showSettings:sender]; }
@end

#pragma mark - Connection sheet

@implementation ARDMConnectionSheetController {
    NSWindow *_sheet;
    NSWindow *_parent;
    ARDMConnectionConfig *_config;
    NSMutableDictionary<NSNumber *, NSTextField *> *_fields;
    NSMutableDictionary<NSNumber *, NSButton *> *_switches;
    void (^_completion)(ARDMConnectionConfig * _Nullable);
}

+ (void)presentForConfig:(ARDMConnectionConfig *)config inWindow:(NSWindow *)window completion:(void (^)(ARDMConnectionConfig *))completion {
    ARDMConnectionSheetController *c = [[ARDMConnectionSheetController alloc] init];
    c->_config = config ?: [[ARDMConnectionConfig alloc] init];
    c->_parent = window;
    c->_completion = completion;
    c->_fields = [NSMutableDictionary dictionary];
    c->_switches = [NSMutableDictionary dictionary];
    [c build];
    static ARDMConnectionSheetController *active = nil;
    active = c;
    [window beginSheet:c->_sheet completionHandler:^(NSModalResponse response) { active = nil; (void)active; }];
}

- (NSTextField *)addField:(NSString *)label value:(NSString *)value tag:(NSInteger)tag y:(CGFloat)y to:(NSView *)parent {
    [parent addSubview:ARDMLabel(label, NSMakeRect(20, y, 160, 22))];
    NSTextField *f = ARDMInput(value, NSMakeRect(190, y, 360, 24), tag);
    [parent addSubview:f]; _fields[@(tag)] = f;
    return f;
}

- (void)addSwitch:(NSString *)title on:(BOOL)on tag:(NSInteger)tag y:(CGFloat)y to:(NSView *)parent x:(CGFloat)x {
    NSButton *b = ARDMSwitch(title, NSMakeRect(x, y, 220, 22), on, tag);
    [parent addSubview:b]; _switches[@(tag)] = b;
}

- (void)build {
    _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 560)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered defer:NO];
    _sheet.title = @"Redis Connection";
    NSView *root = _sheet.contentView;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 60, 580, 470)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *basic = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 440)];
    CGFloat y = 400;
    NSArray *rows = @[@[@"Name", @"name", @"100"], @[@"Host", @"host", @"101"], @[@"Port", @"port", @"102"],
                      @[@"Password", @"auth", @"103"], @[@"ACL Username", @"username", @"104"],
                      @[@"Group", @"group", @"105"], @[@"Tree Separator", @"separator", @"106"],
                      @[@"Database Index", @"db", @"107"], @[@"Client Name", @"connectionName", @"108"]];
    NSDictionary *values = [_config toDictionary];
    for (NSArray *row in rows) {
        NSString *key = row[1]; NSInteger tag = [row[2] integerValue];
        id v = values[key];
        [self addField:row[0] value:[v isKindOfClass:NSString.class] ? v : [NSString stringWithFormat:@"%@", v]
                   tag:tag y:y to:basic];
        y -= 34;
    }
    _fields[@(103)].placeholderString = @"Auth (leave empty if none)";
    [self addSwitch:@"Read-only mode" on:_config.readOnly tag:200 y:80 to:basic x:20];
    [self addSwitch:@"Cluster" on:_config.cluster tag:201 y:80 to:basic x:240];
    [self addSwitch:@"SSH Tunnel" on:_config.sshEnabled tag:202 y:52 to:basic x:20];
    [self addSwitch:@"TLS / SSL" on:_config.tlsEnabled tag:203 y:52 to:basic x:240];
    [self addSwitch:@"Sentinel" on:_config.sentinelEnabled tag:204 y:24 to:basic x:20];

    NSView *ssh = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 440)];
    y = 400;
    NSArray *sshRows = @[@[@"SSH Host", @"sshHost", @"110"], @[@"SSH Port", @"sshPort", @"111"],
                         @[@"SSH User", @"sshUser", @"112"], @[@"SSH Password", @"sshPassword", @"113"],
                         @[@"Private Key Path", @"sshPrivateKey", @"114"], @[@"Passphrase", @"sshPassphrase", @"115"],
                         @[@"Timeout (s)", @"sshTimeout", @"116"]];
    for (NSArray *row in sshRows) {
        id v = values[row[1]];
        [self addField:row[0] value:[NSString stringWithFormat:@"%@", v] tag:[row[2] integerValue] y:y to:ssh];
        y -= 40;
    }

    NSView *tls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 440)];
    y = 400;
    for (NSArray *row in @[@[@"SNI Server Name", @"tlsSNI", @"120"], @[@"CA File", @"tlsCA", @"121"],
                           @[@"Client Cert", @"tlsCert", @"122"], @[@"Client Key", @"tlsKey", @"123"]]) {
        [self addField:row[0] value:values[row[1]] tag:[row[2] integerValue] y:y to:tls];
        y -= 40;
    }

    NSView *sentinel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 440)];
    [self addField:@"Master Group Name" value:values[@"sentinelMaster"] tag:130 y:400 to:sentinel];
    [self addField:@"Node Password" value:values[@"sentinelNodePassword"] tag:131 y:360 to:sentinel];

    NSTabViewItem *i1 = [[NSTabViewItem alloc] initWithIdentifier:@"basic"]; i1.label = @"General"; i1.view = basic;
    NSTabViewItem *i2 = [[NSTabViewItem alloc] initWithIdentifier:@"ssh"]; i2.label = @"SSH"; i2.view = ssh;
    NSTabViewItem *i3 = [[NSTabViewItem alloc] initWithIdentifier:@"tls"]; i3.label = @"TLS"; i3.view = tls;
    NSTabViewItem *i4 = [[NSTabViewItem alloc] initWithIdentifier:@"sentinel"]; i4.label = @"Sentinel"; i4.view = sentinel;
    [tabs addTabViewItem:i1]; [tabs addTabViewItem:i2]; [tabs addTabViewItem:i3]; [tabs addTabViewItem:i4];
    [root addSubview:tabs];

    NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(400, 15, 90, 30)];
    cancel.title = @"Cancel"; cancel.bezelStyle = NSBezelStyleRounded; cancel.target = self; cancel.action = @selector(cancel:);
    NSButton *test = [[NSButton alloc] initWithFrame:NSMakeRect(495, 15, 90, 30)];
    test.title = @"Test"; test.bezelStyle = NSBezelStyleRounded; test.target = self; test.action = @selector(test:);
    [root addSubview:cancel]; [root addSubview:test];
    NSButton *save = [[NSButton alloc] initWithFrame:NSMakeRect(20, 15, 120, 30)];
    save.title = @"Save & Connect"; save.bezelStyle = NSBezelStyleRounded; save.target = self; save.action = @selector(save:);
    save.keyEquivalent = @"\r"; [root addSubview:save];
}

- (NSString *)stringForTag:(NSInteger)tag { return _fields[@(tag)].stringValue ?: @""; }
- (NSInteger)intForTag:(NSInteger)tag { return [self stringForTag:tag].integerValue; }
- (BOOL)boolForTag:(NSInteger)tag { return _switches[@(tag)].state == NSControlStateValueOn; }

- (ARDMConnectionConfig *)collect {
    ARDMConnectionConfig *c = [_config copy];
    c.name = [self stringForTag:100]; c.host = [self stringForTag:101]; c.port = [self intForTag:102] ?: 6379;
    c.auth = [self stringForTag:103]; c.username = [self stringForTag:104]; c.group = [self stringForTag:105];
    c.separator = [self stringForTag:106]; c.db = [self intForTag:107]; c.connectionName = [self stringForTag:108];
    c.readOnly = [self boolForTag:200]; c.cluster = [self boolForTag:201];
    c.sshEnabled = [self boolForTag:202]; c.tlsEnabled = [self boolForTag:203]; c.sentinelEnabled = [self boolForTag:204];
    c.sshHost = [self stringForTag:110]; c.sshPort = [self intForTag:111] ?: 22;
    c.sshUser = [self stringForTag:112]; c.sshPassword = [self stringForTag:113];
    c.sshPrivateKey = [self stringForTag:114]; c.sshPassphrase = [self stringForTag:115];
    c.sshTimeout = [self intForTag:116] ?: 30;
    c.tlsSNI = [self stringForTag:120]; c.tlsCA = [self stringForTag:121];
    c.tlsCert = [self stringForTag:122]; c.tlsKey = [self stringForTag:123];
    c.sentinelMaster = [self stringForTag:130]; c.sentinelNodePassword = [self stringForTag:131];
    return c;
}

- (void)closeWith:(NSModalResponse)response config:(ARDMConnectionConfig *)config {
    [_parent endSheet:_sheet returnCode:response];
    if (_completion) _completion(config);
}

- (void)cancel:(id)sender { [self closeWith:NSModalResponseCancel config:nil]; }
- (void)save:(id)sender { [self closeWith:NSModalResponseOK config:[self collect]]; }
- (void)test:(id)sender {
    ARDMRedisClient *client = [[ARDMRedisClient alloc] initWithConfig:[self collect]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil; BOOL ok = [client connect:&err];
        NSString *message = ok ? [NSString stringWithFormat:@"Connected to %@:%ld", [client hostUsed], (long)[client portUsed]]
                               : [NSString stringWithFormat:@"Failed: %@", err.localizedDescription];
        [client disconnect];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init]; a.messageText = @"Connection Test"; a.informativeText = message;
            [a beginSheetModalForWindow:_sheet completionHandler:nil];
        });
    });
}
@end

#pragma mark - Main window

@interface ARDMMainWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSTableView *connectionTable;
@property (nonatomic, strong) NSTableView *keyTable;
@property (nonatomic, strong) NSTableView *detailTable;
@property (nonatomic, strong) NSTextView *valueView;
@property (nonatomic, strong) NSTextView *cliOutput;
@property (nonatomic, strong) NSTextField *cliInput;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *keyHeader;
@property (nonatomic, strong) NSPopUpButton *dbPopup;
@property (nonatomic, strong) NSPopUpButton *viewerPopup;
@property (nonatomic, strong) NSPopUpButton *languagePopup;
@property (nonatomic, strong) NSTabView *rightTabs;
@property (nonatomic, strong) NSMutableArray<ARDMConnectionConfig *> *connections;
@property (nonatomic, strong) NSMutableArray<NSString *> *keys;
@property (nonatomic, strong) NSArray<NSString *> *detailRows;
@property (nonatomic, strong) ARDMRedisClient *client;
@property (nonatomic, strong) ARDMConnectionConfig *currentConfig;
@property (nonatomic, copy) NSString *selectedKey;
@property (nonatomic, strong) NSData *selectedValue;
@property (nonatomic, assign) NSUInteger scanCursor;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, copy) NSString *customViewerScript;
@property (nonatomic, assign) NSInteger pageSize;
@end

@implementation ARDMMainWindowController

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 720)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Another Redis Desktop Manager — Native";
    [w center];
    if ((self = [super initWithWindow:w])) {
        _connections = [[ARDMConnectionConfig loadAll] mutableCopy];
        _keys = [NSMutableArray array];
        _detailRows = @[];
        _pageSize = [[NSUserDefaults standardUserDefaults] integerForKey:@"ARDMPageSize"] ?: 500;
        _customViewerScript = [[NSUserDefaults standardUserDefaults] stringForKey:@"ARDMCustomViewer"] ?: @"return new TextDecoder().decode(bytes);";
        _darkMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"ARDMDarkMode"];
        [self applyAppearance];
        [self buildUI];
    }
    return self;
}

- (void)applyAppearance {
    NSApp.appearance = self.darkMode ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                                     : [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}

- (void)buildUI {
    NSView *root = self.window.contentView;
    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"ARDMMainToolbar"];
    toolbar.delegate = (id<NSToolbarDelegate>)self;
    [self.window setToolbar:toolbar];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 28, W, H - 28)];
    split.vertical = YES; split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *left = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 230, H - 28)];
    NSView *middle = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, H - 28)];
    NSView *right = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, H - 28)];

    [left addSubview:ARDMLabel(@"Connections", NSMakeRect(10, H - 62, 200, 20))];
    NSScrollView *connectionScroll = ARDMTable(NSMakeRect(0, 40, 230, H - 110), @"Saved connections");
    self.connectionTable = connectionScroll.documentView;
    self.connectionTable.dataSource = self; self.connectionTable.delegate = self;
    self.connectionTable.target = self; self.connectionTable.doubleAction = @selector(connectSelected:);
    connectionScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [left addSubview:connectionScroll];
    NSButton *add = [[NSButton alloc] initWithFrame:NSMakeRect(10, 8, 100, 26)];
    add.title = @"Add…"; add.bezelStyle = NSBezelStyleRounded; add.target = self; add.action = @selector(addConnection:);
    NSButton *edit = [[NSButton alloc] initWithFrame:NSMakeRect(115, 8, 100, 26)];
    edit.title = @"Edit…"; edit.bezelStyle = NSBezelStyleRounded; edit.target = self; edit.action = @selector(editConnection:);
    [left addSubview:add]; [left addSubview:edit];

    self.searchField = ARDMInput(@"", NSMakeRect(10, H - 66, 230, 24), 1);
    self.searchField.placeholderString = @"Filter keys (glob pattern)";
    self.searchField.target = self; self.searchField.action = @selector(reloadKeys:);
    [middle addSubview:self.searchField];
    NSScrollView *keyScroll = ARDMTable(NSMakeRect(0, 40, 320, H - 115), @"Keys");
    self.keyTable = keyScroll.documentView;
    self.keyTable.dataSource = self; self.keyTable.delegate = self;
    keyScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [middle addSubview:keyScroll];
    self.statusLabel = ARDMLabel(@"Not connected", NSMakeRect(10, 10, 300, 20));
    [middle addSubview:self.statusLabel];

    self.keyHeader = ARDMLabel(@"Select a key", NSMakeRect(10, H - 66, 210, 22));
    [right addSubview:self.keyHeader];
    self.viewerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(230, H - 70, 150, 26)];
    [self.viewerPopup addItemsWithTitles:[ARDMFormatters viewerNames]];
    self.viewerPopup.target = self; self.viewerPopup.action = @selector(renderDetail);
    [right addSubview:self.viewerPopup];
    self.dbPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(390, H - 70, 110, 26)];
    for (NSInteger i = 0; i < 16; i++) [self.dbPopup addItemWithTitle:[NSString stringWithFormat:@"DB %ld", (long)i]];
    self.dbPopup.target = self; self.dbPopup.action = @selector(changeDatabase:);
    [right addSubview:self.dbPopup];

    self.rightTabs = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 40, 520, H - 120)];
    self.rightTabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *valuePane = [[NSView alloc] initWithFrame:self.rightTabs.bounds];
    NSScrollView *valueScroll = [[NSScrollView alloc] initWithFrame:valuePane.bounds];
    valueScroll.hasVerticalScroller = YES; valueScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.valueView = [[NSTextView alloc] initWithFrame:valueScroll.bounds];
    self.valueView.font = [NSFont fontWithName:@"Menlo" size:12] ?: [NSFont systemFontOfSize:12];
    self.valueView.editable = YES; self.valueView.autoresizingMask = NSViewWidthSizable;
    valueScroll.documentView = self.valueView; [valuePane addSubview:valueScroll];
    NSView *tablePane = [[NSView alloc] initWithFrame:self.rightTabs.bounds];
    NSScrollView *detailScroll = ARDMTable(tablePane.bounds, @"Value / field");
    self.detailTable = detailScroll.documentView;
    self.detailTable.dataSource = self; self.detailTable.delegate = self;
    detailScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [tablePane addSubview:detailScroll];
    NSView *cliPane = [[NSView alloc] initWithFrame:self.rightTabs.bounds];
    NSScrollView *cliScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 40, cliPane.bounds.size.width, cliPane.bounds.size.height - 40)];
    cliScroll.hasVerticalScroller = YES; cliScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.cliOutput = [[NSTextView alloc] initWithFrame:cliScroll.bounds];
    self.cliOutput.editable = NO; self.cliOutput.font = [NSFont fontWithName:@"Menlo" size:12];
    cliScroll.documentView = self.cliOutput; [cliPane addSubview:cliScroll];
    self.cliInput = ARDMInput(@"", NSMakeRect(0, 6, cliPane.bounds.size.width - 90, 26), 2);
    self.cliInput.placeholderString = @"Redis command, e.g. INFO server";
    self.cliInput.target = self; self.cliInput.action = @selector(runCli:);
    [cliPane addSubview:self.cliInput];
    NSButton *run = [[NSButton alloc] initWithFrame:NSMakeRect(cliPane.bounds.size.width - 85, 6, 80, 26)];
    run.title = @"Run"; run.bezelStyle = NSBezelStyleRounded; run.target = self; run.action = @selector(runCli:);
    [cliPane addSubview:run];
    NSTabViewItem *v1 = [[NSTabViewItem alloc] initWithIdentifier:@"value"]; v1.label = @"Value"; v1.view = valuePane;
    NSTabViewItem *v2 = [[NSTabViewItem alloc] initWithIdentifier:@"table"]; v2.label = @"Structure"; v2.view = tablePane;
    NSTabViewItem *v3 = [[NSTabViewItem alloc] initWithIdentifier:@"cli"]; v3.label = @"CLI"; v3.view = cliPane;
    [self.rightTabs addTabViewItem:v1]; [self.rightTabs addTabViewItem:v2]; [self.rightTabs addTabViewItem:v3];
    [right addSubview:self.rightTabs];

    NSButton *saveValue = [[NSButton alloc] initWithFrame:NSMakeRect(10, 8, 110, 26)];
    saveValue.title = @"Save Value"; saveValue.bezelStyle = NSBezelStyleRounded;
    saveValue.target = self; saveValue.action = @selector(saveValue:);
    NSButton *delKey = [[NSButton alloc] initWithFrame:NSMakeRect(125, 8, 100, 26)];
    delKey.title = @"Delete Key"; delKey.bezelStyle = NSBezelStyleRounded;
    delKey.target = self; delKey.action = @selector(deleteKey:);
    NSButton *ttl = [[NSButton alloc] initWithFrame:NSMakeRect(230, 8, 90, 26)];
    ttl.title = @"Set TTL…"; ttl.bezelStyle = NSBezelStyleRounded;
    ttl.target = self; ttl.action = @selector(setTTL:);
    NSButton *batch = [[NSButton alloc] initWithFrame:NSMakeRect(325, 8, 120, 26)];
    batch.title = @"Batch Delete…"; batch.bezelStyle = NSBezelStyleRounded;
    batch.target = self; batch.action = @selector(batchDelete:);
    [right addSubview:saveValue]; [right addSubview:delKey]; [right addSubview:ttl]; [right addSubview:batch];

    [split addSubview:left]; [split addSubview:middle]; [split addSubview:right];
    [split setPosition:230 ofDividerAtIndex:0];
    [split setPosition:560 ofDividerAtIndex:1];
    split.delegate = (id<NSSplitViewDelegate>)self;
    [root addSubview:split];
    [self.connectionTable reloadData];
}

#pragma mark Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"add", @"connect", @"refresh", @"cli", @"status", @"settings", @"language", NSToolbarFlexibleSpaceItemIdentifier];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"add", @"connect", @"refresh", @"cli", @"status", NSToolbarFlexibleSpaceItemIdentifier, @"language", @"settings"];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.target = self;
    if ([identifier isEqualToString:@"language"]) {
        self.languagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 26)];
        [self.languagePopup addItemsWithTitles:[ARDMLocalization shared].languages];
        [self.languagePopup selectItemWithTitle:[ARDMLocalization shared].currentLanguage];
        self.languagePopup.target = self; self.languagePopup.action = @selector(changeLanguage:);
        item.view = self.languagePopup; item.label = @"Language";
        return item;
    }
    NSDictionary *titles = @{@"add": @"Add Connection", @"connect": @"Connect", @"refresh": @"Refresh",
                             @"cli": @"CLI", @"status": @"Status", @"settings": @"Settings"};
    NSDictionary *actions = @{@"add": @"addConnection:", @"connect": @"connectSelected:", @"refresh": @"reloadKeys:",
                              @"cli": @"showCli:", @"status": @"showStatus:", @"settings": @"showSettings:"};
    item.label = titles[identifier] ?: identifier;
    item.action = NSSelectorFromString(actions[identifier] ?: @"");
    item.paletteLabel = item.label;
    return item;
}

#pragma mark Table data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.connectionTable) return self.connections.count;
    if (tableView == self.keyTable) return self.keys.count;
    return self.detailRows.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == self.connectionTable) return row < (NSInteger)self.connections.count ? self.connections[row].name : @"";
    if (tableView == self.keyTable) return row < (NSInteger)self.keys.count ? self.keys[row] : @"";
    return row < (NSInteger)self.detailRows.count ? self.detailRows[row] : @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.keyTable) {
        NSInteger row = self.keyTable.selectedRow;
        if (row >= 0 && row < (NSInteger)self.keys.count) [self selectKey:self.keys[row]];
    }
}

#pragma mark Connection operations

- (void)addConnection:(id)sender {
    __weak typeof(self) weak = self;
    [ARDMConnectionSheetController presentForConfig:nil inWindow:self.window completion:^(ARDMConnectionConfig *saved) {
        if (!saved) return;
        [weak.connections addObject:saved];
        [ARDMConnectionConfig saveAll:weak.connections];
        [weak.connectionTable reloadData];
        [weak connectToConfig:saved];
    }];
}

- (void)editConnection:(id)sender {
    NSInteger row = self.connectionTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.connections.count) return;
    __weak typeof(self) weak = self;
    [ARDMConnectionSheetController presentForConfig:self.connections[row] inWindow:self.window completion:^(ARDMConnectionConfig *saved) {
        if (!saved) return;
        [weak.connections replaceObjectAtIndex:row withObject:saved];
        [ARDMConnectionConfig saveAll:weak.connections];
        [weak.connectionTable reloadData];
    }];
}

- (void)connectSelected:(id)sender {
    NSInteger row = self.connectionTable.selectedRow;
    if (row < 0 && self.connections.count == 1) row = 0;
    if (row < 0 || row >= (NSInteger)self.connections.count) { [self addConnection:sender]; return; }
    [self connectToConfig:self.connections[row]];
}

- (void)connectToConfig:(ARDMConnectionConfig *)config {
    self.currentConfig = config;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Connecting to %@:%ld…", config.host, (long)config.port];
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ARDMRedisClient *client = [[ARDMRedisClient alloc] initWithConfig:config];
        NSError *err = nil;
        BOOL ok = [client connect:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                weak.statusLabel.stringValue = [NSString stringWithFormat:@"Failed: %@", err.localizedDescription];
                NSAlert *a = [[NSAlert alloc] init]; a.messageText = @"Connection failed";
                a.informativeText = err.localizedDescription ?: @"unknown error";
                [a beginSheetModalForWindow:weak.window completionHandler:nil];
                return;
            }
            [weak.client disconnect];
            weak.client = client;
            weak.statusLabel.stringValue = [NSString stringWithFormat:@"Connected  ·  %@:%ld  ·  DB %ld",
                                            [client hostUsed], (long)[client portUsed], (long)config.db];
            [weak.dbPopup selectItemAtIndex:MIN(config.db, 15)];
            [weak reloadKeys:nil];
        });
    });
}

- (void)changeDatabase:(id)sender {
    NSInteger db = self.dbPopup.indexOfSelectedItem;
    __weak typeof(self) weak = self;
    [self.client asyncSend:@[@"SELECT", [NSString stringWithFormat:@"%ld", (long)db]] completion:^(id reply, NSError *error) {
        if (error) { weak.statusLabel.stringValue = error.localizedDescription; return; }
        weak.client.selectedDB = db;
        [weak reloadKeys:nil];
    }];
}

#pragma mark Key operations

- (void)reloadKeys:(id)sender {
    if (!self.client) return;
    NSString *pattern = self.searchField.stringValue.length ? self.searchField.stringValue : @"*";
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger cursor = 0;
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        NSError *err = nil;
        do {
            NSArray *batch = [weak.client scanKeysMatching:pattern cursor:&cursor count:weak.pageSize error:&err];
            [all addObjectsFromArray:batch];
        } while (cursor > 0 && all.count < 100000);
        dispatch_async(dispatch_get_main_queue(), ^{
            [all sortUsingSelector:@selector(compare:)];
            weak.keys = all;
            [weak.keyTable reloadData];
            weak.statusLabel.stringValue = [NSString stringWithFormat:@"%lu keys  ·  DB %ld  ·  %@:%ld",
                (unsigned long)all.count, (long)weak.client.selectedDB, [weak.client hostUsed], (long)[weak.client portUsed]];
        });
    });
}

- (void)selectKey:(NSString *)key {
    self.selectedKey = key;
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        ARDMKeyType type = [weak.client typeOfKey:key error:&err];
        NSInteger ttl = [weak.client ttlOfKey:key error:nil];
        id value = [weak.client valueOfKey:key type:type error:&err];
        NSData *raw = nil;
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        if ([value isKindOfClass:NSData.class]) raw = value;
        else if ([value isKindOfClass:NSString.class]) raw = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
        else if ([value isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)value) {
                NSString *s = [item isKindOfClass:NSData.class]
                    ? ([[NSString alloc] initWithData:item encoding:NSUTF8StringEncoding] ?: [item description])
                    : [NSString stringWithFormat:@"%@", item];
                [rows addObject:s];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *typeNames = @[@"string", @"list", @"set", @"zset", @"hash", @"stream", @"ReJSON", @"TimeSeries", @"Vector", @"Array", @"unknown"];
            weak.keyHeader.stringValue = [NSString stringWithFormat:@"%@  ·  %@  ·  TTL %ld",
                key, typeNames[MIN(type, ARDMKeyTypeUnknown)], (long)ttl];
            weak.selectedValue = raw ?: [NSData data];
            weak.detailRows = rows;
            [weak.detailTable reloadData];
            [weak.viewerPopup selectItemWithTitle:[ARDMFormatters detectViewerForData:weak.selectedValue]];
            [weak renderDetail];
        });
    });
}

- (void)renderDetail {
    NSString *viewer = self.viewerPopup.titleOfSelectedItem ?: @"Text";
    NSError *err = nil;
    NSString *text = [viewer isEqualToString:@"Custom"]
        ? [ARDMFormatters renderCustom:self.selectedValue script:self.customViewerScript error:&err]
        : [ARDMFormatters render:self.selectedValue as:viewer error:&err];
    self.valueView.string = err ? [NSString stringWithFormat:@"Viewer error: %@", err.localizedDescription] : (text ?: @"");
}

- (void)saveValue:(id)sender {
    if (!self.selectedKey) return;
    NSString *text = self.valueView.string;
    __weak typeof(self) weak = self;
    [self.client asyncSend:@[@"SET", self.selectedKey, text] completion:^(id reply, NSError *error) {
        if (error) weak.statusLabel.stringValue = error.localizedDescription;
        else weak.statusLabel.stringValue = @"Value saved";
    }];
}

- (void)deleteKey:(id)sender {
    if (!self.selectedKey) return;
    __weak typeof(self) weak = self;
    [self.client asyncSend:@[@"DEL", self.selectedKey] completion:^(id reply, NSError *error) {
        if (!error) { [weak.keys removeObject:weak.selectedKey]; [weak.keyTable reloadData]; weak.selectedKey = nil; }
        else weak.statusLabel.stringValue = error.localizedDescription;
    }];
}

- (void)setTTL:(id)sender {
    if (!self.selectedKey) return;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Set TTL (seconds)"; a.informativeText = @"Use -1 to persist the key.";
    [a addButtonWithTitle:@"Apply"]; [a addButtonWithTitle:@"Cancel"];
    NSTextField *input = ARDMInput(@"3600", NSMakeRect(0, 0, 180, 24), 3); a.accessoryView = input;
    __weak typeof(self) weak = self;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSInteger seconds = input.stringValue.integerValue;
        NSArray *args = seconds < 0 ? @[@"PERSIST", weak.selectedKey]
                                    : @[@"EXPIRE", weak.selectedKey, @(seconds).stringValue];
        [weak.client asyncSend:args completion:^(id r, NSError *e) { [weak selectKey:weak.selectedKey]; }];
    }];
}

- (void)batchDelete:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Batch delete"; a.informativeText = @"Delete all keys matching a glob pattern.";
    [a addButtonWithTitle:@"Delete"]; [a addButtonWithTitle:@"Cancel"];
    NSTextField *input = ARDMInput(self.searchField.stringValue ?: @"tmp:*", NSMakeRect(0, 0, 220, 24), 4);
    a.accessoryView = input;
    __weak typeof(self) weak = self;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn || !input.stringValue.length) return;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSUInteger cursor = 0; NSInteger deleted = 0;
            do {
                NSArray *batch = [weak.client scanKeysMatching:input.stringValue cursor:&cursor count:500 error:nil];
                for (NSString *k in batch) { [weak.client send:@[@"DEL", k] error:nil]; deleted++; }
            } while (cursor > 0);
            dispatch_async(dispatch_get_main_queue(), ^{
                weak.statusLabel.stringValue = [NSString stringWithFormat:@"Deleted %ld keys", (long)deleted];
                [weak reloadKeys:nil];
            });
        });
    }];
}

#pragma mark CLI, status and auxiliary panels

- (void)runCli:(id)sender {
    NSString *line = self.cliInput.stringValue;
    if (!line.length) return;
    self.cliInput.stringValue = @"";
    [self.cliOutput.textStorage appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"> %@\n", line]]];
    NSArray *args = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *p in args) if (p.length) [clean addObject:p];
    if (!clean.count) return;
    __weak typeof(self) weak = self;
    [self.client asyncSend:clean completion:^(id reply, NSError *error) {
        NSString *text = error ? [NSString stringWithFormat:@"(error) %@\n", error.localizedDescription]
                               : [NSString stringWithFormat:@"%@\n", [self.class describeReply:reply]];
        [weak.cliOutput.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    }];
}

+ (NSString *)describeReply:(id)reply {
    if (!reply || reply == NSNull.null) return @"(nil)";
    if ([reply isKindOfClass:NSData.class]) {
        return [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] ?: [NSString stringWithFormat:@"(binary %lu bytes)", (unsigned long)[(NSData *)reply length]];
    }
    if ([reply isKindOfClass:NSArray.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        NSInteger i = 1;
        for (id item in (NSArray *)reply) [parts addObject:[NSString stringWithFormat:@"%ld) %@", (long)i++, [self describeReply:item]]];
        return [parts componentsJoinedByString:@"\n"];
    }
    return [NSString stringWithFormat:@"%@", reply];
}

- (void)showCli:(id)sender { [self.rightTabs selectTabViewItemWithIdentifier:@"cli"]; [self.window makeFirstResponder:self.cliInput]; }
- (void)showCommandLog:(id)sender { [self showTextPanel:@"Command Log" lines:[self.client.logs valueForKey:@"command"]]; }
- (void)showHotkeys:(id)sender {
    [self showTextPanel:@"Keyboard Shortcuts" lines:@[@"⌘N  New connection", @"⌘R  Refresh keys", @"⌘T  Redis CLI",
        @"⌘D  Toggle dark mode", @"⌘,  Settings", @"↩  Connect / run CLI command"]];
}

- (void)showTextPanel:(NSString *)title lines:(NSArray *)lines {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = lines.count ? [lines componentsJoinedByString:@"\n"] : @"(empty)";
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)showStatus:(id)sender {
    [self showRawCommand:@[@"INFO"] title:@"Server Status"];
}

- (void)showSlowLog:(id)sender { [self showRawCommand:@[@"SLOWLOG", @"GET", @"20"] title:@"Slow Log"]; }
- (void)showMemoryAnalysis:(id)sender { [self showRawCommand:@[@"MEMORY", @"STATS"] title:@"Memory Analysis"]; }

- (void)showRawCommand:(NSArray *)args title:(NSString *)title {
    __weak typeof(self) weak = self;
    [self.client asyncSend:args completion:^(id reply, NSError *error) {
        NSString *text = error ? error.localizedDescription : [self.class describeReply:reply];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init]; a.messageText = title; a.informativeText = text;
            [a beginSheetModalForWindow:weak.window completionHandler:nil];
        });
    }];
}

- (void)showSettings:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Settings";
    a.informativeText = [NSString stringWithFormat:@"Keys per page: %ld\nLanguage: %@\nTheme: %@\nCustom viewer: JavaScript (JavaScriptCore)\n\nEdit these in the connection sheet or use the toolbar language menu.",
                         (long)self.pageSize, [ARDMLocalization shared].currentLanguage, self.darkMode ? @"Dark" : @"Light"];
    [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Toggle Theme"];
    NSTextField *page = ARDMInput([NSString stringWithFormat:@"%ld", (long)self.pageSize], NSMakeRect(0, 0, 200, 24), 5);
    a.accessoryView = page;
    __weak typeof(self) weak = self;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSInteger n = page.stringValue.integerValue;
        if (n > 0) { weak.pageSize = n; [[NSUserDefaults standardUserDefaults] setInteger:n forKey:@"ARDMPageSize"]; }
        if (response == NSAlertSecondButtonReturn) [weak toggleTheme:nil];
    }];
}

- (void)toggleTheme:(id)sender {
    self.darkMode = !self.darkMode;
    [[NSUserDefaults standardUserDefaults] setBool:self.darkMode forKey:@"ARDMDarkMode"];
    [self applyAppearance];
}

- (void)changeLanguage:(id)sender {
    [ARDMLocalization shared].currentLanguage = self.languagePopup.titleOfSelectedItem ?: @"en";
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Language: %@", [ARDMLocalization shared].currentLanguage];
}

- (void)importConnections:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.allowedFileTypes = @[@"json"];
    __weak typeof(self) weak = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSData *d = [NSData dataWithContentsOfURL:panel.URL];
        NSArray *raw = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![raw isKindOfClass:NSArray.class]) return;
        for (NSDictionary *item in raw) [weak.connections addObject:[ARDMConnectionConfig fromDictionary:item]];
        [ARDMConnectionConfig saveAll:weak.connections]; [weak.connectionTable reloadData];
    }];
}

- (void)exportConnections:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = @"ardm-connections.json";
    __weak typeof(self) weak = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSMutableArray *raw = [NSMutableArray array];
        for (ARDMConnectionConfig *c in weak.connections) [raw addObject:[c toDictionary]];
        NSData *d = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:nil];
        [d writeToURL:panel.URL atomically:YES];
    }];
}
@end

#pragma mark - Entry point

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        ARDMAppDelegate *delegate = [[ARDMAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
