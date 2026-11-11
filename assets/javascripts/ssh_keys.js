function setupSshKeys() {
  const form = document.querySelector('#ssh-key-title');
  const preview = document.querySelector('#ssh-key-public');
  if (!form || !preview) {
    return;
  }
  preview.addEventListener('input', () => {
    const value = preview.value.trim();
    const valid = /^ssh-(rsa|ed25519|ecdsa|ssh-dss)\s+[A-Za-z0-9+/=]+/.test(value);
    preview.classList.toggle('is-invalid', value.length > 0 && !valid);
  });
}
