"""Generate BurrowBolt's editable Icon Composer layers: a mole over lightning roots."""
import json
from pathlib import Path
out = Path(__file__).parent / 'AppIcon.icon'
assets = out / 'Assets'
assets.mkdir(parents=True, exist_ok=True)
for old in assets.glob('*.svg'):
    old.unlink()
shapes = [
    ('roots', '#FFC857', '<path d="M487 520L413 673H493L430 887L606 651H531L585 520Z M390 541L260 648H342L233 804L450 637H371L466 541Z M619 541L759 652H684L797 801L574 635H649L556 541Z"/>'),
    ('mole', '#D8DBD6', '<path d="M244 480C238 363 323 235 439 232C545 193 683 256 729 365L820 430L735 501C698 573 593 591 490 554C396 595 290 563 244 480Z"/><ellipse cx="309" cy="519" rx="79" ry="38"/><ellipse cx="661" cy="531" rx="76" ry="35"/>'),
    ('face', '#102F30', '<circle cx="619" cy="362" r="20"/><path d="M784 404Q842 424 803 451L772 450Z"/><path d="M692 457Q721 473 745 452" fill="none" stroke="#102F30" stroke-width="12" stroke-linecap="round"/><path d="M267 523L267 548M296 532L296 557M324 532L324 557M635 543L635 565M666 545L666 566M696 539L696 561" stroke="#102F30" stroke-width="10" stroke-linecap="round"/>'),
]
layers=[]
for name, color, shape in shapes:
    (assets / (name + '.svg')).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><g fill="{color}">{shape}</g></svg>\n')
    layers.append({'name':name,'image-name':name+'.svg','glass':name!='face'})
icon={'fill':{'linear-gradient':['srgb:0.07,0.24,0.24,1','srgb:0.025,0.09,0.12,1'],'orientation':{'start':{'x':0.1,'y':0},'stop':{'x':0.9,'y':1}}},'groups':[{'layers':layers,'lighting':'individual','specular':True,'shadow':{'kind':'neutral','opacity':0.35},'translucency':{'enabled':False,'value':0.3}}],'supported-platforms':{'squares':['macOS']}}
(out / 'icon.json').write_text(json.dumps(icon,indent=2)+'\n')
