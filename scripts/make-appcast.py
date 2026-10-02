#!/usr/bin/env python3
"""產生 Sparkle 的更新清單 appcast.xml（只放最新一版）。release.sh 會呼叫；測自動更新時也可以手動用。

用法：make-appcast.py <zip> <版本號> <內部版號> <zip 的下載網址> <更新說明> > appcast.xml
zip 會用 vendor/Sparkle/bin/sign_update 簽名（私鑰在鑰匙圈的 agent-island 帳號），簽名寫進清單，app 會先驗證才安裝。
"""
import html
import os
import re
import subprocess
import sys
from email.utils import formatdate

zip_path, version, build, url, notes = sys.argv[1:6]
root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sig = subprocess.run([os.path.join(root, "vendor/Sparkle/bin/sign_update"), "--account", "agent-island", zip_path],
                     capture_output=True, text=True, check=True).stdout.strip()
if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', sig):
    sys.exit("sign_update 的輸出看不懂：" + sig)
body = "<br>".join(html.escape(line) for line in notes.splitlines())

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Island</title>
    <item>
      <title>Agent Island {html.escape(version)}</title>
      <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{body}</p>]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {sig}/>
    </item>
  </channel>
</rss>""")
