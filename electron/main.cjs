const { app, BrowserWindow, dialog, Menu, session } = require('electron');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const entryPath = path.join(__dirname, '..', 'dist', 'index.html');
const entryUrl = pathToFileURL(entryPath).href;
const gamePermissions = new Set(['pointerLock', 'fullscreen']);

app.setName('NACHTGANG');

function isGameDocument(webContents, details = {}) {
  return Boolean(
    webContents &&
      !webContents.isDestroyed() &&
      webContents.getURL() === entryUrl &&
      details.isMainFrame !== false &&
      (!details.requestingUrl || details.requestingUrl === entryUrl),
  );
}

function installSessionRules() {
  const gameSession = session.defaultSession;
  gameSession.setPermissionCheckHandler((contents, permission, _origin, details) => {
    return gamePermissions.has(permission) && isGameDocument(contents, details);
  });
  gameSession.setPermissionRequestHandler((contents, permission, callback, details) => {
    callback(gamePermissions.has(permission) && isGameDocument(contents, details));
  });
  gameSession.on('will-download', (event) => event.preventDefault());

  // The desktop game ships all assets locally and does not need a network connection.
  gameSession.webRequest.onBeforeRequest(
    { urls: ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*'] },
    (_details, callback) => callback({ cancel: true }),
  );
}

function installMenu() {
  const isMac = process.platform === 'darwin';
  const appMenu = isMac
    ? {
        label: 'NACHTGANG',
        submenu: [
          { role: 'about', label: 'Über NACHTGANG' },
          { type: 'separator' },
          { role: 'hide', label: 'NACHTGANG ausblenden' },
          { role: 'hideOthers', label: 'Andere ausblenden' },
          { role: 'unhide', label: 'Alle einblenden' },
          { type: 'separator' },
          { role: 'quit', label: 'NACHTGANG beenden' },
        ],
      }
    : { label: 'Spiel', submenu: [{ role: 'quit', label: 'Beenden' }] };

  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      appMenu,
      {
        label: 'Bearbeiten',
        submenu: [
          { role: 'undo', label: 'Rückgängig' },
          { role: 'redo', label: 'Wiederholen' },
          { type: 'separator' },
          { role: 'cut', label: 'Ausschneiden' },
          { role: 'copy', label: 'Kopieren' },
          { role: 'paste', label: 'Einfügen' },
          { role: 'selectAll', label: 'Alles auswählen' },
        ],
      },
      {
        label: 'Ansicht',
        submenu: [
          {
            role: 'togglefullscreen',
            label: 'Vollbild',
            accelerator: isMac ? 'Control+Command+F' : 'F11',
          },
          ...(!app.isPackaged
            ? [
                { type: 'separator' },
                { role: 'toggleDevTools', label: 'Entwicklerwerkzeuge' },
              ]
            : []),
        ],
      },
    ]),
  );
}

async function createWindow() {
  const window = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 640,
    title: 'NACHTGANG — BLACKSITE',
    backgroundColor: '#090d0e',
    show: false,
    autoHideMenuBar: process.platform !== 'darwin',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      allowRunningInsecureContent: false,
      autoplayPolicy: 'user-gesture-required',
    },
  });

  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  window.webContents.on('will-redirect', (event) => event.preventDefault());
  window.webContents.on('will-attach-webview', (event) => event.preventDefault());
  window.once('ready-to-show', () => window.show());
  await window.loadFile(entryPath);
}

function showStartupError(error) {
  dialog.showErrorBox(
    'NACHTGANG konnte nicht starten',
    `Die Spieldateien konnten nicht geladen werden. Bitte die Anwendung neu erstellen oder installieren.\n\n${error.message}`,
  );
  app.quit();
}

app.whenReady().then(async () => {
  installSessionRules();
  installMenu();
  await createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow().catch(showStartupError);
    }
  });
}).catch(showStartupError);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
