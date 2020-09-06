
# Audio file preparation
```
wget https://upload.wikimedia.org/wikipedia/commons/f/f3/Anthem_of_Europe_%28US_Navy_instrumental_short_version%29.ogg
sox Anthem_of_Europe_\(US_Navy_instrumental_short_version\).ogg -c 1 -e signed-integer -r 8000 --endian little -b 16 demo.s16
paplay --format=s16le --rate=8000 --raw demo.s16
```

