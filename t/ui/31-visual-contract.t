# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Warnings ':report_warnings';
use Mojo::JSON qw(decode_json);
use OpenQA::Test::TimeLimit '60';
use OpenQA::Test::VisualFixtures qw(init_visual_data login visual_pages);
use OpenQA::SeleniumTest;

init_visual_data;
driver_missing unless my $driver = call_driver;
disable_timeout;
my $url = OpenQA::SeleniumTest::get_mojo_url;
login($driver, $url);
my %hidden_pages = map { $_ => 1 } qw(front_page group_overview);

my $font_helper = <<'JS';
const loaded = new Set(Array.from(document.fonts).filter(f => f.status === 'loaded').map(f => f.family));
const firstFamily = s => s.split(',')[0].replace(/^["']|["']$/g, '').trim();
JS

sub icon_problems () {
    return $driver->execute_script($font_helper . <<'JS');
const visible = Array.from(document.querySelectorAll('i[class*="fa-"]'))
  .filter(el => { const rect = el.getBoundingClientRect(); return rect.width && rect.height; });
return JSON.stringify(visible.flatMap(el => {
  const style = getComputedStyle(el);
  const problems = [];
  const family = firstFamily(style.fontFamily);
  if (!loaded.has(family)) problems.push(el.className + ' refers to family ' + family + ' which is not loaded');
  if (el.classList.contains('fa-fw') && style.getPropertyValue('--fa-width') !== '1.25em')
    problems.push('fa-fw icon ' + el.className + ' has --fa-width ' + style.getPropertyValue('--fa-width'));
  return problems;
}));
JS
}

sub bubble_problems () {
    return $driver->execute_script($font_helper . <<'JS');
const bubbles = Array.from(document.querySelectorAll('.openqa-label, .openqa-flag'));
return JSON.stringify([bubbles.filter(e => !loaded.has(firstFamily(getComputedStyle(e, '::before').fontFamily)))
  .map(e => e.className + ' refers to a family that is not loaded'), bubbles.length]);
JS
}

sub overlap_problems () {
    return $driver->execute_script(<<'JS');
const following = el => {
  const next = el.nextSibling;
  if (next && next.nodeType === 3 && next.textContent.trim()) {
    const range = document.createRange();
    range.selectNode(next);
    return range.getBoundingClientRect();
  }
  return next && next.nodeType === 1 ? next.getBoundingClientRect() : null;
};
const icons = Array.from(document.querySelectorAll('i[class*="fa-"]')).map(el => ({el, box: el.getBoundingClientRect()}))
  .filter(({box}) => box.width !== 0);
return JSON.stringify(icons.filter(({el, box}) => {
  const f = following(el);
  return f && f.width !== 0 && box.right > f.left + 0.5 && box.left < f.right - 0.5
    && box.bottom > f.top && box.top < f.bottom;
}).map(({el}) => el.className + ' overlaps the content following it'));
JS
}

sub visually_hidden_problems () {
    return $driver->execute_script(<<'JS');
const elements = Array.from(document.querySelectorAll('.visually-hidden'));
const problems = elements.map(el => ({el, style: getComputedStyle(el)}))
  .filter(({style}) => !(style.width === '1px' && style.height === '1px' && style.overflow === 'hidden'
    && style.position === 'absolute' && style.whiteSpace === 'nowrap' && /rect\(0/.test(style.clip)))
  .map(({el, style}) => el.tagName + '.' + el.className + ' is not visually hidden (width=' + style.width
    + ', position=' + style.position + ', clip=' + style.clip + ')');
return JSON.stringify([problems, elements.length]);
JS
}

sub check_page ($name, $path, $click = undef) {
    $driver->get($url . $path);
    wait_for_ajax_and_animations;
    $driver->find_element(qq{//a[contains(text(), "$click (")]}, 'xpath')->click if $click;
    wait_for_ajax_and_animations;
    my $icons = decode_json(icon_problems());
    is_deeply $icons, [], "$name: every icon is rendered with a loaded font family" or diag join "\n", @$icons;
    my $overlap = decode_json(overlap_problems());
    is_deeply $overlap, [], "$name: no icon overlaps the content following it" or diag join "\n", @$overlap;
    my ($hidden, $hidden_count) = @{decode_json(visually_hidden_problems())};
    is_deeply $hidden, [], "$name: elements hiding content for screen readers stay hidden" or diag join "\n", @$hidden;
    cmp_ok $hidden_count, '>=', 1, "$name: page renders content hidden for screen readers" if $hidden_pages{$name};
    my ($bubbles, $count) = @{decode_json(bubble_problems())};
    is_deeply $bubbles, [], "$name: comment label and flag bubbles use a loaded font family"
      or diag join "\n", @$bubbles;
    cmp_ok $count, '>=', 2, "$name: label and flag bubbles rendered via CSS content are present" if $click;
}

for my $page (visual_pages) {
    my ($name, $path) = @$page;
    subtest $name => sub {
        check_page($name, $path, $name eq 'test_details' ? 'Comments' : undef);
    };
}

kill_driver;
done_testing();
