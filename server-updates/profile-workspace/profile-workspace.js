/* Account controls for the existing Nightwell web client. No playback replacement. */
(() => {
  'use strict';
  let owner = null, profile = {nickname: '', avatar_url: ''}, avatarKey = '', pending = false;
  const style = document.createElement('style');
  style.textContent = `
    #header-menu {position:fixed!important;left:auto!important;right:16px!important;top:76px!important;width:min(280px,calc(100vw - 32px))!important;max-height:min(380px,calc(100dvh - 100px))!important;overflow:auto!important;overscroll-behavior:contain;border-radius:18px!important}
    #header-menu .nav,#header-menu .account {min-height:40px!important;padding:9px 14px!important;font-size:14px!important;box-sizing:border-box;width:100%}
    #header-menu [hidden] {display:none!important}
    #header-menu-toggle {border-radius:50%!important;overflow:hidden;padding:0!important;background:#303030!important;color:#eee!important}
    #header-menu-toggle img {width:100%;height:100%;object-fit:cover}
    #header-menu-toggle .nw-initial {display:grid;place-items:center;width:100%;height:100%;font:600 18px system-ui}
    #visual-settings {max-height:calc(100dvh - 40px)!important;max-width:calc(100vw - 28px)!important;overflow:auto!important;box-sizing:border-box}
    .nw-profile-card {padding:18px;margin:14px 0;border:1px solid #ffffff18;border-radius:18px;background:#ffffff06;display:grid;gap:12px}
    .nw-profile-card h3 {margin:0;font-size:17px}.nw-profile-card input {max-width:100%;box-sizing:border-box;background:#292929;color:#eee;border:1px solid #555;border-radius:12px;padding:12px;font:inherit}
    .nw-profile-card button {background:#333;color:#eee;border:1px solid #555;border-radius:12px;padding:11px 14px;font:inherit;text-align:left}
    .nw-profile-card [role=status] {font-size:13px;color:#ccc;white-space:pre-wrap}
    #music-transfer-open {display:none!important}
    dialog {max-width:calc(100vw - 28px);max-height:calc(100dvh - 32px);box-sizing:border-box;overflow:auto}
  `;
  document.head.append(style);
  const uid = () => typeof user !== 'undefined' ? user?.id || '' : '';
  const button = (text, action) => {const b = document.createElement('button');b.type = 'button';b.textContent = text;b.onclick = action;return b;};
  function clampMenu() {
    const menu = document.getElementById('header-menu'), anchor = document.getElementById('header-menu-toggle');
    if (!menu || !anchor || menu.hidden) return;
    const r = anchor.getBoundingClientRect();
    const top = Math.max(8, Math.min(r.bottom + 8, innerHeight - 140));
    menu.style.setProperty('top', top + 'px', 'important');
    menu.style.setProperty('max-height', Math.max(96, Math.min(380, innerHeight - top - 12)) + 'px', 'important');
  }
  function sync() {
    const id = uid(), menu = document.getElementById('header-menu'), toggle = document.getElementById('header-menu-toggle');
    if (!menu || !toggle) return;
    const account = document.getElementById('account'), nav = menu.querySelector('nav');
    for (const node of menu.querySelectorAll('.nav')) {
      const home = node.dataset.view === 'catalog', settings = node.id === 'settings-open';
      const removed = node.dataset.view === 'search' || /^(Настройка подборки|Настроить подборку|Перенести музыку)$/.test(node.textContent.trim());
      const hidden = removed || (!id && !home && !settings) || (node.id === 'admin-link' && !user?.is_admin);
      if (node.hidden !== hidden) node.hidden = hidden;
      if (home) {const label = node.querySelector('span');if (label && label.textContent !== 'Главная') label.textContent = 'Главная';}
    }
    if (account) {if (!id && menu.firstElementChild !== account) menu.prepend(account);if (id && menu.lastElementChild !== account) menu.append(account);}
    if (owner !== id) {
      owner = id;profile = {nickname: '', avatar_url: ''};
      document.getElementById('nw-profile-card')?.remove();document.getElementById('nw-transfer-category')?.remove();
      if (id) void api('/api/profile').then(result => {if (uid() === id) {profile = result;sync();}}).catch(() => {});
    }
    const key = id + '|' + profile.nickname + '|' + profile.avatar_url;
    if (key !== avatarKey) {
      avatarKey = key;toggle.replaceChildren();
      const initial = document.createElement('span');initial.className = 'nw-initial';initial.textContent = id ? [...(profile.nickname || 'N')][0].toUpperCase() : '♙';toggle.append(initial);
      if (id && profile.avatar_url) {const url = new URL(profile.avatar_url, location.origin);if (url.origin === location.origin) {const img = document.createElement('img');img.alt = '';img.src = url.href;img.onload = () => {if (avatarKey === key) {toggle.replaceChildren(img);}};}}
    }
    toggle.title = profile.nickname || 'Меню';
    buildSettings(id);const name = document.querySelector('#nw-profile-card input:not([type=file])');if(name && !name.dataset.dirty && document.activeElement !== name && name.value !== profile.nickname) name.value = profile.nickname;clampMenu();
  }
  function buildSettings(id) {
    const settings = document.getElementById('visual-settings');
    if (!settings || !id || document.getElementById('nw-profile-card')) return;
    const card = document.createElement('section');card.id = 'nw-profile-card';card.className = 'nw-profile-card';
    const heading = document.createElement('h3');heading.textContent = 'Профиль';
    const name = document.createElement('input');name.maxLength = 40;name.placeholder = 'Никнейм';name.value = profile.nickname;name.oninput = () => name.dataset.dirty = '1';name.setAttribute('aria-label', 'Никнейм');
    const note = document.createElement('div');note.setAttribute('role', 'status');
    async function save(path, method, body) {
      if (pending || uid() !== id) return;pending = true;card.querySelectorAll('button').forEach(b => b.disabled = true);
      try {const result = await api(path, method, body);if (uid() === id) {profile = result;note.textContent = 'Сохранено';sync();}}
      catch (error) {note.textContent = error.message;}
      finally {pending = false;card.querySelectorAll('button').forEach(b => b.disabled = false);}
    }
    const file = document.createElement('input');file.type = 'file';file.accept = 'image/jpeg,image/png,image/webp';file.hidden = true;
    file.onchange = async () => {
      const value = file.files?.[0];if (!value) return;
      if (value.size > 12 * 1024 * 1024) {note.textContent = 'Выбери изображение до 12 МБ';return;}
      try {
        const bitmap = await createImageBitmap(value), scale = Math.min(1, 512 / Math.max(bitmap.width, bitmap.height));
        const canvas = document.createElement('canvas');canvas.width = Math.max(1, Math.round(bitmap.width * scale));canvas.height = Math.max(1, Math.round(bitmap.height * scale));canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);bitmap.close();
        await save('/api/profile/avatar', 'POST', {image: canvas.toDataURL('image/jpeg', .88).split(',')[1]});
      } catch {note.textContent = 'Не удалось прочитать изображение';}finally {file.value = '';}
    };
    card.append(heading, name, button('Сохранить ник', () => save('/api/profile', 'PUT', {nickname: name.value.trim()})), button('Выбрать аватарку', () => file.click()), button('Удалить аватарку', () => save('/api/profile/avatar', 'DELETE')), file, note);
    settings.querySelector('header')?.after(card);
    const transfer = document.createElement('section');transfer.id = 'nw-transfer-category';transfer.className = 'nw-profile-card';
    const title = document.createElement('h3');title.textContent = 'Перенос музыки';
    transfer.append(title, button('Перенести плейлисты и избранное', () => {settings.close();window.nwOpenMusicTransfer?.();}));card.after(transfer);
  }
  function schedule() {queueMicrotask(sync);}
  document.addEventListener('nightwell:viewchange', sync);
  document.addEventListener('visibilitychange', () => {if (!document.hidden && uid()) {const id = uid();void api('/api/profile').then(p => {if (id === uid()) {profile = p;sync();}}).catch(() => {});}});
  window.addEventListener('resize', clampMenu);
  document.addEventListener('click', event => {if (event.target.closest('#header-menu-toggle,#settings-open')) schedule();});
  sync();
  const nav = document.querySelector('#header-menu nav');if (nav) new MutationObserver(sync).observe(nav, {childList: true});
})();
