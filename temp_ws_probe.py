import urllib.request
req = urllib.request.Request('http://127.0.0.1:5000/ws')
try:
    r = urllib.request.urlopen(req, timeout=5)
    print('status', r.status)
    print(r.read(200).decode('utf-8','ignore'))
except Exception as e:
    print(type(e).__name__, e)
