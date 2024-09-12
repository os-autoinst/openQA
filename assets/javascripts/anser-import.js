const module = {};

// https://github.com/IonicaBizau/anser/pull/75
// https://datatracker.ietf.org/doc/html/rfc3986#appendix-A
function linkify(txt) {
  const re = /(https?:\/\/(?:[A-Za-z0-9#;/?:@=+$',_.!~*()[\]-]|&amp;|%[A-Fa-f0-9]{2})+)/gm;
  return txt.replace(re, function (str) {
    return '<a href="' + str + '">' + str + '</a>';
  });
}
function ansiToHtml(data) {
  return linkify(Anser.ansiToHtml(Anser.escapeForHtml(data), {use_classes: true}));
}
function ansiToText(data) {
  return Anser.ansiToText(data);
}
