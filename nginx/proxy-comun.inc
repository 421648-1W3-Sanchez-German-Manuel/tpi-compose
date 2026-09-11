# Lo que todo location que reenvia al gateway necesita. En un include para que
# no se le olvide a ninguno: un location sin X-Forwarded-For rompe el rate limit
# por IP en silencio (el gateway ve la IP de nginx y mete a todos en el mismo
# bucket), y eso no se nota hasta que alguien se queda sin login.

proxy_http_version 1.1;
proxy_set_header Connection "";

proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;

# NO se limpian los X-Principal-Type / X-User-* aca a proposito: de eso se
# encarga IdentityPropagationFilter en el gateway, que los borra del request
# entrante antes de poner los suyos. Hacerlo en dos lugares invita a que alguien
# despues "simplifique" el del gateway, que es el que importa.

# Mas corto que el timeout del TimeLimiter del gateway (3 s) no tiene sentido:
# el gateway ya corta antes y contesta 503 con Retry-After. Esto es la red de
# atras, para que nginx no se quede colgado si el gateway deja de responder.
proxy_connect_timeout 5s;
proxy_send_timeout    30s;
proxy_read_timeout    30s;

# El gateway devuelve problem+json en los errores; que nginx no los reemplace
# por su pagina HTML.
proxy_intercept_errors off;
