# Bitácora de desarrollo — Vías Topográficas

## 2026-11-11 — Inicio y fases 1–2

- Se creó el cargador de la extensión, el menú de SketchUp y el botón de barra de herramientas.
- Se añadió el formulario HtmlDialog con parámetros de calle, bordillo, acera, talud y pendiente máxima. El ancho inicial de bordillo es 0,15 m.
- Se aplicó el tema oscuro con texto blanco.
- La selección valida dos grupos: terreno con caras y eje con aristas.
- El motor del eje ordena las aristas, detecta ramificaciones y segmentos desconectados, genera estaciones Catmull–Rom y proyecta cotas sobre el grupo de terreno.
- El perfil longitudinal se suaviza y se limita por pendiente máxima; la excepción de pendiente se aplica al tramo abierto que desciende monotónicamente desde una cota alta a una baja.
- Se añadió un instalador PowerShell con lanzador `.bat`, copias de seguridad y destino SketchUp 2026 configurado.

### Estado al cerrar las fases 1 y 2

- Fases 1 y 2 implementadas en código; no verificadas dentro de SketchUp con un modelo real.
- Las estaciones y parámetros calculados quedan en memoria para que los consuman las siguientes fases.

## 2026-11-11 — Fase 3 y cambio de nombre

- El nombre visible de la extensión cambió a `TOPO_ROAD`; se conserva la carpeta técnica interna para que el instalador pueda actualizar instalaciones existentes.
- Se añadió el generador de sección transversal y extrusión longitudinal.
- La generación crea cuatro grupos independientes: vía, acera, bordillo y talud.
- El bordillo usa su ancho configurable dentro del ancho total de acera; las secciones transversales mantienen cotas horizontales por estación.
- Los taludes conectan el borde exterior de acera con puntos del terreno muestreados al final del ancho de proyección.
- El generador no se ha validado todavía en SketchUp con modelos de prueba; hay que comprobar el resultado en geometrías abiertas, cerradas y curvas cerradas.

## 2026-11-11 — Fase 4: recorte y costura del terreno

- Se añaden muros temporales para intersectar la huella exterior con la malla topográfica.
- Se eliminan las caras de terreno dentro de la huella y se conserva el terreno exterior; en circuitos cerrados se conserva el área interior.
- Se añaden triángulos al grupo de talud entre el borde triangulado del terreno cortado y la proyección de talud para coser diferencias de cota.
- Se rechazan tramos no adyacentes del eje que se acercan a una distancia igual o inferior al ancho de calzada.
- La fusión booleana de taludes solapados sin conflicto con la calzada sigue pendiente de validación y desarrollo adicional.
- La Fase 4 no se ha ejecutado todavía en SketchUp con modelos reales.
