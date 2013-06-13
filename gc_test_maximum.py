import re
import string
import sys

file = open(sys.argv[1],"r")
file.readline() # skip header
body = file.read()
g = body.count("G")
c = body.count("C")
t = body.count("T")
a = body.count("A")
gcCount = g+c
totalBaseCount = g+c+t+a
if gcCount == 0:
	gcFraction = 0
else:
	gcFraction = float(gcCount) / totalBaseCount
print( gcFraction * 100 )
