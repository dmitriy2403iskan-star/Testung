# Обучение на Kaggle (бесплатно, с телефона)

1. Зарегистрируйся на kaggle.com, подтверди телефон (Settings → Phone verification). Без этого интернет в ноутбуке не включается.
2. Create → New Notebook. В меню ноутбука: File → Import Notebook (или Upload) → загрузи `train/kaggle_train.ipynb` из репозитория.
   Либо просто создай пустой ноутбук и вставь в ячейку:
   ```
   import os
   os.environ['SECS'] = '10800'
   !rm -rf Testung && git clone -q https://github.com/dmitriy2403iskan-star/Testung
   !python Testung/train/kaggle_run.py
   ```
3. Settings (справа): **Internet: On**, Accelerator: None (процессор).
4. Save Version → **Save & Run All (Commit)**. Оно считается в фоне, вкладку можно закрыть.
5. Когда закончится: вкладка Output → `result.zip` (там `pretrained/skills.json`, `REPORT.md`, логи).
   Статус во время работы: Versions → открой версию → Logs.

Скачанный `pretrained/skills.json` положи в репозиторий в папку `pretrained/` (через GitHub: Add file → Upload files).
Автоотправка: если в Kaggle (Add-ons → Secrets) добавить секрет `TESTUNG_PUSH_TOKEN` с токеном GitHub (доступ Contents: write к репозиторию), результат отправится сам.
