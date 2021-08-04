from testapi import *


def run(self):
    assert_screen('openqa-logged-in')
    assert_and_click('openqa-search')
    type_string('shutdown.pm')
    send_key('ret')
    assert_screen('openqa-search-results')
