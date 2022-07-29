import os
import Levenshtein
import pickle
from http import client
from openqa_client.client import OpenQA_Client
import time

"""
This script scans all the autoinst-log.txt in the testresults directory.
Then find the error messages in the autoinst-log.txt.
Use Levenshtein to calculate the text distance.
Finally, post the results as comments by OpenQA_Client.
"""

# gather all the autoinst-log.txt
logs = []
for root, dirs, files in os.walk("testresults"):
    for name in files:
        if name == "autoinst-log.txt":
            logs.append(os.path.join(root, name))

# I used a .pkl file to store some intermediate computation results to reduce time cost.
# This part finds error messages in autoinst-log.txt
# Maybe there are multiple errors in a single autoinst-log.txt
# I think some different code may trigger the same bug.
# The first line is the most important, so I focus on the first lines of the errors.
if not os.path.exists("id_msg.pkl"):
    id_msg = {}
    for path in logs:
        with open(path, 'r') as f:
            text = f.read()
            anchor = 0
            begin = text.find("Test died", anchor)
            while begin != -1:
                anchor = begin + 1
                end = text.find("\n", begin)
                # print(text[begin:end])
                # print(path.split("\\")[1])
                id_msg[path.split("\\")[1]] = text[begin:end]
                begin = text.find("Test died", anchor)

    # print(id_msg)
    with open("id_msg.pkl", "wb") as f:
        pickle.dump(id_msg, f)
# If there exists the .pkl file
else:
    with open("id_msg.pkl", "rb") as f:
        id_msg = pickle.load(f)

# Compute the Levenshtein result and save it.
# Saving the result in a file may be unnecessary.
result = {}
f = open("LevenshteinResult.txt", "w")
for index, (key1, value1) in enumerate(id_msg.items()):
    calculate = {}
    for key2, value2 in id_msg.items():
        if key1 == key2:
            continue
        calculate[key2] = Levenshtein.distance(value1, value2)
    # print(calculate)
    calculate_sorted = sorted(calculate.items(), key=lambda x: x[1], reverse=False)
    # print(calculate_sorted)
    f.write("Index: " + str(index) + "\n")
    f.write("Original error message:\n")
    f.write("Job ID: " + key1 + "\n")
    f.write(value1 + "\n")
    # print(value1)
    f.write("matched error message (top 10):\n")
    matched_results = []
    for i in range(10):
        # print(id_msg[calculate_sorted[i][0]])
        f.write("Job ID: " + calculate_sorted[i][0] + "\n")
        f.write(id_msg[calculate_sorted[i][0]] + "\n")
        matched_results.append(calculate_sorted[i][0])
    f.write("\n")
    result[key1] = matched_results

# print(result)

# Post the results in comments by OpenQA_Client
client = OpenQA_Client(server="http://127.0.0.1:9526")
for origin, matched in result.items():
    data = {'bugrefs': [], 'created': time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + " +0000"}
    text = "Top 10 similar failures:\r\n"
    rendered_markdown = "<p>Top 10 similar failures:</p>\n"
    for job_id in matched:
        text += "[" + job_id + "](https://openqa.opensuse.org/tests/" + job_id + ")\r\n"
        rendered_markdown += '<p><a href="https://openqa.opensuse.org/tests/' + job_id + '">' + job_id + '</a>\n'
    data['renderedMarkdown'] = rendered_markdown
    data['text'] = text
    data['updated'] = data['created']
    data['userName'] = 'Demo'
    client.openqa_request('POST', 'jobs/' + origin + '/comments', data)

