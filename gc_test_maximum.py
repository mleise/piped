import re
import string

file = open("Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa","r")
file.readline() # skip header
body = file.read()
g = body.count("G")
c = body.count("C")
t = body.count("T")
a = body.count("A")
gcCount = g+c
totalBaseCount = g+c+t+a
gcFraction = float(gcCount) / totalBaseCount
print( gcFraction * 100 )
