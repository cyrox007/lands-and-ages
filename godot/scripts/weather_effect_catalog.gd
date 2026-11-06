extends RefCounted
## Этап 11.0: каталог реально поставляемых атмосферных ресурсов.
## Все эффекты построены из исходного кода Godot и процедурных
## материалов: сторонних ассетов и скрытых внешних лицензий нет.


static func entries() -> Array[Dictionary]:
	# Каждый элемент связываем с реальным файлом или генератором.
	# Отдельное происхождение позволяет контролировать лицензии
	# при будущей замене собственных эффектов готовыми моделями.
	var source := "собственная процедурная генерация; сторонних ассетов нет"
	return [
		{"id": "rain", "title": "Дождь, морось и ливень",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.rainfall", "license": source},
		{"id": "snow", "title": "Снег",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.snowfall", "license": source},
		{"id": "wet_snow", "title": "Мокрый снег",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.rainfall + snowfall + temperature", "license": source},
		{"id": "hail", "title": "Град",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.storm_intensity + rainfall", "license": source},
		{"id": "splashes", "title": "Дождевые брызги",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.rainfall", "license": source},
		{"id": "snowdrift", "title": "Снежная позёмка",
			"kind": "gpu_particles", "file": "res://shaders/local_precipitation.gdshader",
			"physical_source": "Climate.snowfall + wind_gust", "license": source},
		{"id": "gusts", "title": "Порывы ветра",
			"kind": "gpu_particles", "file": "res://scripts/weather_fx_controller.gd",
			"physical_source": "Climate.wind_gust / NaturalDisasters", "license": source},
		{"id": "dust", "title": "Пылевая завеса",
			"kind": "gpu_particles", "file": "res://scripts/weather_fx_controller.gd",
			"physical_source": "NaturalDisasters: пыльная буря", "license": source},
		{"id": "clouds", "title": "Облачные пятна и освещение",
			"kind": "shader", "file": "res://shaders/natural_ground.gdshader",
			"physical_source": "Climate.humidity + storm_intensity", "license": source},
		{"id": "lightning", "title": "Канал молнии и световые импульсы",
			"kind": "procedural_mesh", "file": "res://scripts/lightning_fx_controller.gd",
			"physical_source": "WeatherEvents.last_events", "license": source},
		{"id": "thunder", "title": "Гром с пространственной задержкой",
			"kind": "generated_audio", "file": "res://scripts/lightning_fx_controller.gd",
			"physical_source": "WeatherEvents.last_events", "license": source}
	]
