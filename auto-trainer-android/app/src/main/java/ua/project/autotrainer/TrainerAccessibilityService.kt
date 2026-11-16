package ua.project.autotrainer
import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.os.Environment
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
class TrainerAccessibilityService : AccessibilityService() {
 private val prefs by lazy { getSharedPreferences("trainer", MODE_PRIVATE) }
 private var lastText=""
 private var streak=0
 private var episode=0
 private val log=mutableListOf<String>()
 override fun onServiceConnected(){ super.onServiceConnected(); Toast.makeText(this,"Auto Trainer запущен",Toast.LENGTH_SHORT).show() }
 override fun onAccessibilityEvent(event: AccessibilityEvent?){
  if(event==null) return
  val target=prefs.getString("target_package","").orEmpty()
  if(target.isBlank() || event.packageName?.toString()!=target) return
  val root=rootInActiveWindow ?: return
  val text=collect(root).trim(); if(text.isBlank() || text==lastText) return; lastText=text
  val success=match(text,"success_words"); val fail=match(text,"fail_words")
  if(success==fail) return
  episode++
  if(success){ streak++; log.add("episode=$episode,result=success"); Toast.makeText(this,"Успех $streak/10",Toast.LENGTH_SHORT).show(); if(streak>=10){ saveSkill(); streak=0 } }
  else { streak=0; log.add("episode=$episode,result=fail"); Toast.makeText(this,"Неуспех: серия сброшена",Toast.LENGTH_SHORT).show() }
  clickNext(root)
 }
 private fun match(text:String,key:String):Boolean { val h=text.lowercase(Locale.getDefault()); return prefs.getString(key,"").orEmpty().split(",").map{it.trim().lowercase(Locale.getDefault())}.any{it.isNotBlank()&&h.contains(it)} }
 private fun collect(n:AccessibilityNodeInfo):String { val s=StringBuilder(); fun walk(x:AccessibilityNodeInfo?){ if(x==null)return; x.text?.toString()?.takeIf{it.isNotBlank()}?.let{s.append(it).append("\n")}; x.contentDescription?.toString()?.takeIf{it.isNotBlank()}?.let{s.append(it).append("\n")}; for(i in 0 until x.childCount) walk(x.getChild(i)) }; walk(n); return s.toString() }
 private fun clickNext(root:AccessibilityNodeInfo){ for(label in listOf("Следующий","Новый эпизод","Повторить","Начать")){ for(n in root.findAccessibilityNodeInfosByText(label)){ var x:AccessibilityNodeInfo?=n; while(x!=null){ if(x.isClickable){x.performAction(AccessibilityNodeInfo.ACTION_CLICK); return}; x=x.parent } } } }
 private fun saveSkill(){ val dir=getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)?:filesDir; val f=File(dir,"trainer_skill.json"); val stamp=SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.US).format(Date()); val items=log.takeLast(50).joinToString(","){ "\"$it\"" }; f.writeText("{\"version\":1,\"created\":\"$stamp\",\"consecutive_successes\":10,\"episodes\":[$items]}"); Toast.makeText(this,"trainer_skill.json сохранён",Toast.LENGTH_LONG).show() }
 override fun onInterrupt(){}
}