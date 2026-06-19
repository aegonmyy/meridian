import pysubs2

subs = pysubs2.load("C:/Users/Alameen/Downloads/moves/SUBS/Snowfall - 4x10 - Fight or Flight.WEB.en.srt")

subs.shift(s=9)
subs.save("C:/Users/Alameen/Downloads/moves/SUBS/fixed.srt")