#!/usr/bin/env python3
"""Create synthetic EXIF photos and an alpha logo in a NEW directory (Pillow required).

Usage: python3 scripts/make-watermark-fixtures.py /tmp/Almaeng-Watermark-Demo-New
No personal files or downloaded image assets are used.
"""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, TiffImagePlugin

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
args = parser.parse_args()
base = args.directory.expanduser().resolve()
base.mkdir(parents=True, exist_ok=False)
photos = base / "Photos"
photos.mkdir()
(base / "Output").mkdir()
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Avenir Next.ttc',34)
small=ImageFont.truetype('/System/Library/Fonts/Supplemental/Avenir Next.ttc',20)
for i,(w,h) in enumerate([(1200,800),(1600,1000),(900,1300),(1400,1000),(1100,800),(1800,1200),(1000,800),(1500,900)]):
 im=Image.new('RGB',(w,h));d=ImageDraw.Draw(im)
 for y in range(h): d.line((0,y,w,y),fill=(int(24+y/h*45),int(44+y/h*65),int(76+y/h*55)))
 r=w*.07;x=w*(.28+i*.055);y=h*.28
 d.ellipse((x-r,y-r,x+r,y+r),fill='#f0c276')
 d.polygon([(0,h*.68),(w*.23,h*.38),(w*.5,h*.65),(w*.75,h*.33),(w,h*.62),(w,h),(0,h)],fill='#386c74')
 d.polygon([(0,h*.85),(w*.3,h*.6),(w*.6,h*.84),(w*.9,h*.58),(w,h*.65),(w,h),(0,h)],fill='#25474e')
 d.text((40,35),f'LIGHT STUDY  {i+1:02}',font=font,fill='#fff1d4')
 d.text((40,h-52),'SYNTHETIC DEMO / ALMAENG RE',font=small,fill='#cae0df')
 exif=Image.Exif();exif[271]='ALMAENG CAMERA' if i%2==0 else 'NORTHCAM';exif[272]=f'Studio {1+i%3}'
 exif[34665]={36867:f'2026:10:{1+(i*3)%8:02} 08:{i*5:02}:00',33434:TiffImagePlugin.IFDRational(1,[60,125,250,500,1000,30,200,400][i]),33437:TiffImagePlugin.IFDRational([28,40,56,80,110,20,32,63][i],10),34855:100*(1+i%4),37386:TiffImagePlugin.IFDRational(35+i*5,1),42036:'Demo Prime',40961:1}
 im.save(photos/f'Study-{i+1:02}.jpg',quality=94,exif=exif)
logo=Image.new('RGBA',(700,190),(0,0,0,0));d=ImageDraw.Draw(logo)
d.ellipse((18,27,146,155),outline='#f0c276',width=9);d.line((47,120,80,67,121,120),fill='#f0c276',width=8)
logofont=ImageFont.truetype('/System/Library/Fonts/Supplemental/Avenir Next.ttc',54)
d.text((175,32),'ALMAENG',font=logofont,fill='white');d.text((180,105),'PHOTO NOTES',font=font,fill='#f0c276')
logo.save(base/'Demo-Signature.png')
print(base)
