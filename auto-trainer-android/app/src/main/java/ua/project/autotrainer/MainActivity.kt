package ua.project.autotrainer
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.*
class MainActivity : Activity() {
 private val prefs by lazy { getSharedPreferences("trainer", MODE_PRIVATE) }
 override fun onCreate(b: Bundle?) {
  super.onCreate(b)
  val box=LinearLayout(this); box.orientation=LinearLayout.VERTICAL; box.setPadding(32,32,32,32)
  val title=TextView(this); title.text="Auto Trainer"; title.textSize=26f; title.gravity=Gravity.CENTER; box.addView(title)
  val info=TextView(this); info.text="Отдельный оператор: симулятор сюда не входит."; info.setPadding(0,20,0,20); box.addView(info)
  val pkg=EditText(this); pkg.hint="Package ID Testung"; pkg.setText(prefs.getString("target_package","")); pkg.setSingleLine(); box.addView(pkg)
  val ok=EditText(this); ok.hint="Успех: слова через запятую"; ok.setText(prefs.getString("success_words","успех,успешно,готов,стою,эпизод заверш")); ok.setSingleLine(); box.addView(ok)
  val bad=EditText(this); bad.hint="Неуспех: слова через запятую"; bad.setText(prefs.getString("fail_words","упал,падение,провал,нет,−")); bad.setSingleLine(); box.addView(bad)
  val save=Button(this); save.text="Сохранить"; save.setOnClickListener { prefs.edit().putString("target_package",pkg.text.toString().trim()).putString("success_words",ok.text.toString()).putString("fail_words",bad.text.toString()).apply(); Toast.makeText(this,"Сохранено",Toast.LENGTH_SHORT).show() }; box.addView(save)
  val acc=Button(this); acc.text="Открыть Спец. возможности"; acc.setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }; box.addView(acc)
  val status=TextView(this); status.setPadding(0,24,0,0); status.text="Сервис работает только после явного включения пользователем."; box.addView(status)
  setContentView(box)
 }
}