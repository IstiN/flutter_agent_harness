window.__fahFsOpen = function() {
  if (!window.__fahFsDbPromise) {
    window.__fahFsDbPromise = new Promise(function(resolve, reject) {
      var req = indexedDB.open('fah_web_fs', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('snapshots')) {
          db.createObjectStore('snapshots');
        }
      };
      req.onsuccess = function() { resolve(req.result); };
      req.onerror = function() {
        window.__fahFsDbPromise = null;
        reject(req.error);
      };
    });
  }
  return window.__fahFsDbPromise;
};
window.__fahFsLoad = function() {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var req = db.transaction('snapshots', 'readonly')
        .objectStore('snapshots').get('sandbox');
      req.onsuccess = function() {
        resolve(req.result === undefined ? null : req.result);
      };
      req.onerror = function() { reject(req.error); };
    });
  });
};
window.__fahFsSave = function(snapshot) {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      txn.objectStore('snapshots').put(snapshot, 'sandbox');
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
    });
  });
};
