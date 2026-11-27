import Anser from 'anser';

function ansiToHtml(data) {
  return Anser.linkify(Anser.ansiToHtml(Anser.escapeForHtml(data), {use_classes: true}));
}
function ansiToText(data) {
  return Anser.ansiToText(data);
}
window.ansiToHtml = ansiToHtml;
window.ansiToText = ansiToText;
