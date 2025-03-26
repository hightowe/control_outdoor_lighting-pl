# control_outdoor_lighting.pl
A simple perl script to control outdoor lighting via a KAUF Smart Plug.

This script and a KAUF Smart Plug allows for automation with no cloud
components and with no additional home automation infrastructure, such
as Home Assistant or ESPHome.

## KAUF Smart Plugs
This program was written with a KAUF PLF12 (https://kaufha.com/plf12)
but it should also work with a KAUF PLF10 (https://kaufha.com/plf10)
if you remove the power consumption sensor readings code that the PLF10
does not support.

