#!/usr/bin/env python3
"""Check release identity and immutable URLs without modifying the signed feed."""
import pathlib,sys,xml.etree.ElementTree as ET
path=pathlib.Path(sys.argv[1]);tag=sys.argv[2]
assert tag.startswith('burrowbolt-v')
namespace='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root=ET.parse(path).getroot()
items=root.findall('./channel/item')
assert len(items)==1, 'Expected one immutable release in this feed'
item=items[0];enclosure=item.find('enclosure')
assert item.findtext(namespace+'version')==tag.removeprefix('burrowbolt-v')
assert item.findtext(namespace+'minimumSystemVersion') in ('14.0','14.0.0')
assert item.findtext(namespace+'hardwareRequirements')=='arm64'
assert enclosure.get('url')==f'https://github.com/masonjames/burrowbolt/releases/download/{tag}/BurrowBolt.dmg'
assert enclosure.get(namespace+'edSignature') and int(enclosure.get('length'))>0
print('PASS: immutable BurrowBolt appcast identity, macOS minimum, architecture and asset signature field')
