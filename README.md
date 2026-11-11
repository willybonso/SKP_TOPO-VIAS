# Vías Topográficas para SketchUp

## Fases 1 y 2: interfaz y motor matemático del eje

La extensión añade **Extensiones → Vías Topográficas → Configurar vía…** y un botón en la barra de herramientas. El formulario captura ancho total de calle, opción y ancho de bordillo, ancho y altura de acera, ancho de talud y pendiente máxima.

### Selección requerida

Selecciona exactamente dos grupos antes de validar:

- El terreno debe contener caras.
- El eje debe contener aristas y no contener caras.

La selección puede validarse desde el formulario. Los parámetros se aceptan solo cuando la selección es válida y los valores numéricos están dentro de rango. Al pulsar **Analizar eje**, la Fase 2 ordena la topología, rechaza desconexiones y ramificaciones, genera estaciones Catmull–Rom, proyecta sus cotas al terreno y suaviza el perfil vertical. El límite de pendiente se aplica con ajuste Lipschitz; se permite excederlo en un tramo abierto cuando desciende monotónicamente desde una cota alta hasta una cota baja. Las estaciones y parámetros quedan en memoria para conectar con la generación geométrica de las siguientes fases.

### Instalación para desarrollo

Ejecuta `Instalar_o_actualizar_Vias_Topograficas.bat` para instalar o actualizar en SketchUp 2026. El script guarda una copia de seguridad de los archivos anteriores. Reinicia SketchUp después de instalar.
