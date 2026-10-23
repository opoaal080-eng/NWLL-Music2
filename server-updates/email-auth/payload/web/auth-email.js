'use strict';
(() => {
  const form = document.getElementById('auth-form');
  if (!form) return;
  const submit = document.getElementById('auth-submit');
  const error = document.getElementById('auth-error');
  const password = document.getElementById('password');
  const email = document.getElementById('email') || form.querySelector('[name=email]');
  let challenge = null, busy = false, timer = null;
  const card = document.createElement('div');
  card.hidden = true;
  const hint = document.createElement('p');
  const code = document.createElement('input');
  code.type = 'text'; code.inputMode = 'numeric'; code.autocomplete = 'one-time-code';
  code.placeholder = 'Код из 6 цифр'; code.maxLength = 6;
  code.setAttribute('aria-label', 'Код подтверждения из письма');
  const note = document.createElement('p');
  const resend = document.createElement('button'); resend.type = 'button';
  const change = document.createElement('button'); change.type = 'button'; change.textContent = 'Изменить данные';
  card.append(hint, code, note, resend, change);
  submit.before(card);
  code.addEventListener('input', () => { code.value = code.value.replace(/[^0-9]/g, '').slice(0, 6); });
  function reset() {
    challenge = null; card.hidden = true; code.required = false; code.value = '';
    if (timer) clearInterval(timer); timer = null;
    if (email) email.disabled = false;
    if (password) password.disabled = false;
    submit.textContent = typeof authMode !== 'undefined' && authMode === 'register' ? 'Создать аккаунт' : 'Войти';
  }
  function tick() {
    if (!challenge) return;
    const remaining = Math.max(0, Math.ceil(challenge.resend_at - Date.now() / 1000));
    const expired = Date.now() / 1000 >= challenge.expires_at;
    resend.textContent = remaining ? `Повторить через ${remaining} с` : 'Отправить код ещё раз';
    resend.disabled = busy || remaining > 0 || expired;
    note.textContent = expired ? 'Код истёк. Начни вход заново.' : 'Код действует 10 минут. Если письма нет, проверь спам.';
  }
  function showChallenge(next) {
    challenge = next; card.hidden = false; code.required = true; code.value = '';
    hint.textContent = 'Письмо отправлено на ' + next.email_hint;
    if (email) email.disabled = true;
    if (password) { password.value = ''; password.disabled = true; }
    submit.textContent = 'Подтвердить код';
    if (timer) clearInterval(timer);
    tick(); timer = setInterval(tick, 1000); code.focus();
  }
  async function send(action, body) {
    const response = await fetch('/api/' + action, { method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || result.detail || 'Не удалось выполнить запрос');
    if (result.verification_required && result.challenge) { showChallenge(result.challenge); return; }
    if (!result.user || !result.csrf) throw new Error('Сервер не подтвердил вход');
    reset(); window.location.reload();
  }
  document.addEventListener('submit', async event => {
    if (event.target !== form) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (busy) return;
    busy = true; submit.disabled = true; change.disabled = true; error.textContent = ''; tick();
    try {
      if (challenge) await send(challenge.action, { challenge_id: challenge.id, code: code.value });
      else {
        const action = typeof authMode !== 'undefined' && authMode === 'register' ? 'register' : 'login';
        await send(action, { email: email.value, password: password.value, supports_email_codes: true });
      }
    } catch (failure) { error.textContent = failure.message; }
    finally { busy = false; submit.disabled = false; change.disabled = false; tick(); }
  }, true);
  resend.addEventListener('click', async () => {
    if (busy || !challenge || resend.disabled) return;
    busy = true; submit.disabled = true; change.disabled = true; error.textContent = ''; tick();
    try { await send(challenge.action, { challenge_id: challenge.id, resend: true }); }
    catch (failure) { error.textContent = failure.message; }
    finally { busy = false; submit.disabled = false; change.disabled = false; tick(); }
  });
  change.addEventListener('click', () => { if (!busy) { reset(); error.textContent = ''; } });
  document.getElementById('auth-switch')?.addEventListener('click', event => {
    if (busy) { event.preventDefault(); event.stopImmediatePropagation(); }
    else reset();
  }, true);
  document.getElementById('close-auth')?.addEventListener('click', reset);
  document.getElementById('auth')?.addEventListener('close', reset);
})();
