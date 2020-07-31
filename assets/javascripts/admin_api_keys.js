function toggleExpiration(expirationCheckBox) {
    const expirationDateTimeField = document.getElementById('expiration-datetime-field');
    if ((expirationDateTimeField.disabled = !expirationCheckBox.checked)) {
        expirationDateTimeField.name = undefined;
    } else {
        expirationDateTimeField.name = 't_expiration';
    }
}