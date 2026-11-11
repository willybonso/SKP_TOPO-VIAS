# Bitácora de desarrollo — Vías Topográficas

## 2026-11-11 — Inicio y fases 1–2

- Se creó el cargador de la extensión, el menú de SketchUp y el botón de barra de herramientas.
- Se añadió el formulario HtmlDialog con parámetros de calle, bordillo, acera, talud y pendiente máxima. El ancho inicial de bordillo es 0,15 m.
- Se aplicó el tema oscuro con texto blanco.
- La selección valida dos grupos: terreno con caras y eje con aristas.
- El motor del eje ordena las aristas, detecta ramificaciones y segmentos desconectados, genera estaciones Catmull–Rom y proyecta cotas sobre el grupo de terreno.
- El perfil longitudinal se suaviza y se limita por pendiente máxima; la excepción de pendiente se aplica al tramo abierto que desciende monotónicamente desde una cota alta a una baja.
- Se añadió un instalador PowerShell con lanzador `.bat`, copias de seguridad y destino SketchUp 2026 configurado.

### Estado y siguiente trabajo

- Fases 1 y 2 implementadas en código; no verificadas dentro de SketchUp con un modelo real.
- Las estaciones y parámetros calculados quedan en memoria. La Fase 3 debe consumirlos para generar la sección y extruir la calzada, acera y bordillo.
- Después quedan pendientes el recorte y adaptación del terreno (Fase 4), además de validaciones geométricas con modelos de prueba.
