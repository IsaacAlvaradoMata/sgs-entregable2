# Convierte un script oficial al formato que DBeaver ejecuta bien con Option + X:
# quita comentarios de linea completa y lineas en blanco, y cambia cada "/" por una linea en blanco
/^[[:space:]]*--/ { next }
/^[[:space:]]*$/  { next }
/^\/[[:space:]]*$/ { print ""; next }
{ print }
